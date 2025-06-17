package main

import "core:flags"
import "core:fmt"
import "core:net"
import os "core:os/os2"
import "core:path/filepath"
import "core:strings"

Args :: struct {
	hot:               bool `flag:"hot"`,
	release:           bool `flag:"release"`,
	sokol_update:      bool `flag:"sokol-update"`,
	sokol_compile:     bool `flag:"sokol-compile"`,
	run:               bool `flag:"run"`,
	debug:             bool `flag:"debug"`,
	no_shader_compile: bool `flag:"no-shader-compile"`,
	web:               bool `flag:"web"`,
	emsdk_path:        string `flag:"emsdk-path"`,
	gl:                bool `flag:"gl"`,
}

ASSETS_PATH :: #config(ASSETS_PATH, "assets")
BUILD_PATH :: #config(BUILD_PATH, "build.nosync")

RELEASE_OUT :: #config(RELEASE_OUT, BUILD_PATH + "/release")
WEB_OUT :: #config(WEB_OUT, BUILD_PATH + "/web")
HOT_OUT :: #config(HOT_OUT, BUILD_PATH + "/hot")

GAME_SRC_PATH :: #config(GAME_SRC_PATH, "src/game")
ENTRY_SRC_DIR :: #config(ENTRY_SRC_DIR, "src/entry")
DLL_NAME :: #config(DLL_NAME, "game_the_dll")

SOKOL_PATH :: #config(SOKOL_PATH, GAME_SRC_PATH + "/sokol")
SOKOL_SHDC_PATH :: #config(SOKOL_SHDC_PATH, "sokol-shdc")

SOKOL_URL :: #config(
	SOKOL_URL,
	"https://github.com/floooh/sokol-odin/archive/refs/heads/main.tar.gz",
)

SOKOL_TOOLS_URL :: #config(
	SOKOL_TOOLS_URL,
	"https://github.com/floooh/sokol-tools-bin/archive/refs/heads/master.tar.gz",
)

WEB_SERVER :: #config(WEB_SERVER, "python3 -m http.server --directory")

main :: proc() {
	args: Args
	flags.parse(&args, os.args[1:], nil)

	num_build_modes := 0
	if args.hot do num_build_modes += 1
	if args.release do num_build_modes += 1
	if args.web do num_build_modes += 1

	if num_build_modes > 1 {
		fmt.println("Can only use one of: -hot, -release and -web.")
		os.exit(1)
	} else if num_build_modes == 0 && !args.sokol_update && !args.sokol_compile {
		fmt.println("You must use one of: -hot, -release, -web, -sokol-update or -sokol-compile.")
		os.exit(1)
	}

	do_update := args.sokol_update || !os.exists(SOKOL_PATH) || !os.exists(SOKOL_SHDC_PATH)
	if do_update {
		if err := update_sokol(); err != nil {
			fmt.eprint("error during sokol update", err)
			os.exit(1)
		}
	}

	do_compile := do_update || args.sokol_compile
	if do_compile {
		if err := compile_sokol(&args); err != nil {
			fmt.eprint("error during sokol compile", err)
			os.exit(1)
		}
	}

	if !args.no_shader_compile {
		if err := build_shaders(&args); err != nil {
			fmt.eprint("error during shader compile", err)
			os.exit(1)
		}
	}

	exe_path := ""
	if args.release {
		exe_path = must(build_release(&args))
	} else if args.web {
		exe_path = must(build_web(&args))
	} else if args.hot {
		exe_path = must(build_hot_reload(&args))
	}

	if exe_path != "" && args.run {
		fmt.printf("Starting %s\n", exe_path)
		if args.web {
			if err := execute2("%s %s", WEB_SERVER, exe_path); err != nil {
				fmt.eprint("error during web compile", err)
				os.exit(1)
			}
		} else {
			dir, file := filepath.split(exe_path)
			os.chdir(dir)

			if err := execute2("./%s", file); err != nil {
				fmt.eprint("error during web compile", err)
				os.exit(1)
			}
		}
	}
}


@(require_results)
update_sokol :: proc() -> os.Error {
	// update_sokol_bindings
	fmt.printfln("Downloading Sokol Odin bindings to directory %s...", SOKOL_PATH)
	download_extract(SOKOL_URL, SOKOL_PATH, "sokol-odin-main/sokol/*") or_return

	// update_sokol_shdc
	fmt.println("Downloading Sokol Shader Compiler to directory %s...", SOKOL_SHDC_PATH)
	download_extract(SOKOL_TOOLS_URL, SOKOL_SHDC_PATH, "sokol-tools-bin-master/bin/*") or_return

	when ODIN_OS == .Linux {
		execute2("chmod +x %s/linux/sokol-shdc", SOKOL_SHDC_PATH) or_return
		execute2("chmod +x %s/linux_arm64/sokol-shdc", SOKOL_SHDC_PATH) or_return
	} else when ODIN_OS == .Darwin {
		execute2("chmod +x %s/osx/sokol-shdc", SOKOL_SHDC_PATH) or_return
		execute2("chmod +x %s/osx_arm64/sokol-shdc", SOKOL_SHDC_PATH) or_return
	}

	return nil
}


@(require_results)
compile_sokol :: proc(args: ^Args) -> os.Error {
	fmt.println("Building Sokol C libraries...")
	emsdk_env := get_emscripten_env_command(args.emsdk_path) or_return

	current_dir := os.get_absolute_path(".", context.temp_allocator) or_return
	os.chdir(SOKOL_PATH)
	defer os.chdir(current_dir)

	when ODIN_OS == .Windows {
		if which("cl.exe") == "" {
			fmt.println(
				"cl.exe not in PATH. Try re-running build.py with flag -compile-sokol from a Visual Studio command prompt.",
			)
			os.exit(1)
		}

		execute2("build_clibs_windows.cmd") or_return

		switch {
		case emsdk_env != "":
			execute2("%s && build_clibs_wasm.bat", emsdk_env) or_return
		case which("emcc.bat") != "":
			execute2("build_clibs_wasm.bat") or_return
		case:
			fmt.println(
				"emcc not in PATH, skipping building of WASM libs. Tip: You can also use -emsdk-path to specify where emscripten lives.",
			)

		}
	} else when ODIN_OS == .Linux || ODIN_OS == .Darwin {
		when ODIN_OS == .Linux {
			execute2("./build_clibs_linux.sh") or_return
		} else when ODIN_OS == .Darwin {
			execute2("./build_clibs_macos.sh && ./build_clibs_macos_dylib.sh") or_return
		}

		switch {
		case emsdk_env != "":
			os.set_env("EMSDK_QUIET", "1") or_return
			execute2("%s && ./build_clibs_wasm.sh", emsdk_env) or_return
		case which("emcc") != "":
			execute2("./build_clibs_wasm.sh") or_return
		case:
			fmt.println(
				"emcc not in PATH, skipping building of WASM libs. " +
				"Tip: You can also use -emsdk-path to specify where emscripten lives.",
			)
		}
	}

	return nil
}


@(require_results)
build_shaders :: proc(args: ^Args) -> os.Error {
	fmt.println("Building shaders...")
	shdc := get_shader_compiler()

	files: [dynamic]string
	append(&files, ..must(filepath.glob(filepath.join({GAME_SRC_PATH, "/*.glsl"}))))
	append(&files, ..must(filepath.glob(filepath.join({GAME_SRC_PATH, "/*/*.glsl"}))))
	append(&files, ..must(filepath.glob(filepath.join({GAME_SRC_PATH, "/*/*/*.glsl"}))))
	append(&files, ..must(filepath.glob(filepath.join({GAME_SRC_PATH, "/*/*/*/*.glsl"}))))
	append(&files, ..must(filepath.glob(filepath.join({GAME_SRC_PATH, "/*/*/*/*/*.glsl"}))))
	append(&files, ..must(filepath.glob(filepath.join({GAME_SRC_PATH, "/*/*/*/*/*/*.glsl"}))))

	langs := ""

	if args.web {
		langs = "glsl300es"
	} else {
		when ODIN_OS == .Windows {
			langs = args.gl ? "glsl430" : "hlsl5"
		} else when ODIN_OS == .Linux {
			langs = "glsl430"
		} else when ODIN_OS == .Darwin {
			langs = args.gl ? "glsl410" : "metal_macos"
		}
	}

	for input in files {
		dir, file := filepath.split(input)
		file = strings.concatenate([]string{"gen__", file[:len(file) - 5], ".odin"})
		output := filepath.join([]string{dir, file})
		cmd := []string{shdc, "-i", input, "-o", output, "-l", langs, "-f", "sokol_odin"}
		fmt.printfln("%s -> %s", input, output)
		execute_cmd(cmd) or_return
	}

	return nil
}


@(require_results)
build_release :: proc(args: ^Args) -> (out: string, err: os.Error) {
	fmt.println("Building release...")

	delete_dir(RELEASE_OUT) or_return
	mkdir(RELEASE_OUT) or_return

	exe := fmt.tprintf("%s/%s", RELEASE_OUT, "game")
	when ODIN_OS == .Windows {
		exe = strings.concatenate([]string{exe, ".exe"})
	}

	cmd: [dynamic]string
	append(
		&cmd,
		..[]string {
			"odin",
			"build",
			fmt.tprintf("%s/release", ENTRY_SRC_DIR),
			fmt.tprintf("-out:%s", exe),
			"-strict-style",
			"-vet",
		},
	)
	if !args.debug {
		append(&cmd, "-no-bounds-check", "-o:speed")
		when ODIN_OS == .Windows {
			append(&cmd, " -subsystem:windows")
		}
	} else {
		append(&cmd, "-debug")
	}

	if args.gl {
		append(&cmd, "-define:SOKOL_USE_GL=true")
	}

	fmt.println("Building Executable...")
	execute_cmd(cmd[:]) or_return
	os.copy_directory_all(RELEASE_OUT, ASSETS_PATH) or_return

	return exe, nil
}

@(require_results)
build_web :: proc(args: ^Args) -> (out: string, err: os.Error) {
	fmt.println("Building web version...")
	delete_dir(WEB_OUT) or_return
	mkdir(WEB_OUT) or_return

	odin_extra_args: string
	if !args.debug {
		odin_extra_args = "-debug"
	}
	fmt.println("Building js_wasm32 game object...")
	execute2(
		"odin build %s/release -target:js_wasm32 -build-mode:obj -vet -strict-style -out:%s/game.wasm.o %s",
		ENTRY_SRC_DIR,
		WEB_OUT,
		odin_extra_args,
	) or_return

	os.copy_file(
		filepath.join([]string{WEB_OUT, "odin.js"}),
		filepath.join([]string{ODIN_ROOT, "core/sys/wasm/js/odin.js"}),
	)

	wasm_lib_suffix := args.debug ? "debug.a" : "release.a"
	emcc_files_str := strings.join(
		[]string {
			WEB_OUT + "/game.wasm.o",
			fmt.tprintf("%s/app/sokol_app_wasm_gl_%s", SOKOL_PATH, wasm_lib_suffix),
			fmt.tprintf("%s/audio/sokol_audio_wasm_gl_%s", SOKOL_PATH, wasm_lib_suffix),
			fmt.tprintf("%s/glue/sokol_glue_wasm_gl_%s", SOKOL_PATH, wasm_lib_suffix),
			fmt.tprintf("%s/gfx/sokol_gfx_wasm_gl_%s", SOKOL_PATH, wasm_lib_suffix),
			fmt.tprintf("%s/shape/sokol_shape_wasm_gl_%s", SOKOL_PATH, wasm_lib_suffix),
			fmt.tprintf("%s/log/sokol_log_wasm_gl_%s", SOKOL_PATH, wasm_lib_suffix),
			fmt.tprintf("%s/gl/sokol_gl_wasm_gl_%s", SOKOL_PATH, wasm_lib_suffix),
		},
		" ",
	)
	// Note --preload-file assets, this bakes in the whole assets directory into
	// the web build.
	emcc_flags := fmt.tprintf(
		"--shell-file %s/release/index_template.html " +
		"--preload-file %s " +
		"-sWASM_BIGINT -sWARN_ON_UNDEFINED_SYMBOLS=0 -sMAX_WEBGL_VERSION=2 -sASSERTIONS",
		ENTRY_SRC_DIR,
		ASSETS_PATH,
	)

	// -g is the emcc debug flag, it makes the errors in the browser console better.
	build_flags := args.debug ? " -g " : ""

	emsdk_env := get_emscripten_env_command(args.emsdk_path) or_return
	// emcc_command: string

	emcc_command := fmt.tprintf(
		"emcc %s -o %s/index.html %s %s",
		build_flags,
		WEB_OUT,
		emcc_files_str,
		emcc_flags,
	)

	if emsdk_env != "" {
		os.set_env("EMSDK_QUIET", "1")
		when ODIN_OS == .Windows {
			emcc_command = fmt.tprintf("%s && %s", msdk_env, emcc_command)
		} else when ODIN_OS == .Linux || ODIN_OS == .Darwin {
			emcc_command = fmt.tprintf("%s && %s", emsdk_env, emcc_command)
		} else {
			fmt.printfln("OS \"%s\" not supported yet", ODIN_OS)
			os.exit(1)
		}
	} else if which("emcc") == "" {
		fmt.println(
			"Could not find emcc. Try providing emscripten SDK path using '-emsdk-path PATH' or run the emsdk_env script inside the emscripten folder before running this script.",
		)
		when ODIN_OS == .Darwin {
			fmt.println("try to run `brew install emscripten`")
		}
		os.exit(1)
	}

	fmt.printfln("Building web application using emscripten to %s...", WEB_OUT)

	execute2(emcc_command) or_return
	os.remove(WEB_OUT + "/game.wasm.o")

	return WEB_OUT, nil
}

@(require_results)
build_hot_reload :: proc(args: ^Args) -> (out: string, err: os.Error) {
	fmt.println("Building hot-reload...")
	out_dir := HOT_OUT

	PROCESS_NAME :: "game_hot"
	game_running := process_exists(PROCESS_NAME)

	if !game_running {
		delete_dir(out_dir) or_return
		mkdir(out_dir) or_return
	}


	dll_file: string
	when ODIN_OS == .Windows {
		dll_file = DLL_NAME + ".dll"
	} else when ODIN_OS == .Linux {
		dll_file = DLL_NAME + ".so"
	} else when ODIN_OS == .Darwin {
		dll_file = DLL_NAME + ".dylib"
	} else {
		return "", .Not_Exist
	}

	dll_path := fmt.tprintf("%s/%s", HOT_OUT, dll_file)


	cmd: [dynamic]string
	append(
		&cmd,
		..[]string {
			"odin",
			"build",
			GAME_SRC_PATH,
			"-define:SOKOL_DLL=true",
			"-build-mode:shared",
			fmt.tprintf("-out:%s", dll_path),
		},
	)
	append_exe_build_args(&cmd, args)


	when ODIN_OS == .Windows {
		// if not game_running:
		// 		out_dir_files = os.listdir(out_dir)
		// 		for f in out_dir_files:
		// 			if f.endswith(".dll"):
		// 				os.remove(os.path.join(out_dir, f))
		// 		if os.path.exists(pdb_dir):
		// 			shutil.rmtree(pdb_dir)
		// 	if not os.path.exists(pdb_dir):
		// 		make_dirs(pdb_dir)
		// 	else:
		// 		pdb_files = os.listdir(pdb_dir)
		// 		for f in pdb_files:
		// 			if f.endswith(".pdb"):
		// 				n = int(f.removesuffix(".pdb").removeprefix("game_"))
		//
		// 				if n > pdb_number:
		// 					pdb_number = n
		// On windows we make sure the PDB name for the DLL is unique on each
		// build. This makes debugging work properly.
		// 	dll_extra_args += " -pdb-name:%s/game_%i.pdb" % (pdb_dir, pdb_number + 1)
	}

	fmt.printfln("Building dynamic library: %s...", dll_path)
	execute_cmd(cmd[:]) or_return

	if game_running {
		fmt.println("Hot reloading...")

		// Hot reloading means the running executable will see the new dll.
		// So we can just return empty string here. This makes sure that the main
		// function does not try to run the executable, even if `run` is specified.
		return "", nil
	}

	exe := HOT_OUT + "/" + PROCESS_NAME
	when ODIN_OS == .Windows {
		exe = HOT_OUT + "/" + PROCESS_NAME + ".exe"
	}

	clear(&cmd)
	append(
		&cmd,
		..[]string {
			"odin",
			"build",
			fmt.tprintf("%s/hot", ENTRY_SRC_DIR),
			"-define:SOKOL_DLL=true",
			fmt.tprintf("-define:DLL_FILE=%s", dll_file),
			fmt.tprintf("-out:%s", exe),
			// "-strict-style",
			// "-vet",
		},
	)

	when ODIN_OS == .Windows {
		append(&cmd, fmt.tprintf("-pdb-name:%s/main_hot_reload.pdb", out_dir))
	}

	append_exe_build_args(&cmd, args)

	fmt.printfln("Building %s...", exe)
	execute_cmd(cmd[:]) or_return

	when ODIN_OS == .Windows {
		// gfxapi = "gl" if args.gl else "d3d11"
		// release_type = "debug" if args.debug else "release"
		// dll_name = "sokol_dll_windows_x64_%s_%s.dll" % (gfxapi, release_type)
		// src = SOKOL_PATH + "/" + dll_name
		// dest = dll_name
		// copy_file_if_different(src, dest)
	} else when ODIN_OS == .Darwin {
		dylib_folder := fmt.tprintf("%s/dylib", SOKOL_PATH)
		if !os.exists(dylib_folder) {
			fmt.println(
				"Dynamic libraries for OSX don't seem to be built." +
				" Please re-run with '-compile-sokol' flag.",
			)
		}

		dylib_rel_path := os.get_relative_path(out_dir, dylib_folder, context.allocator) or_return
		_, dylib_folder_name := filepath.split(dylib_folder)
		os.symlink(dylib_rel_path, fmt.tprintf("%s/%s", out_dir, dylib_folder_name)) or_return
	}

	assets_rel_path := os.get_relative_path(out_dir, ASSETS_PATH, context.allocator) or_return
	_, file := filepath.split(ASSETS_PATH)
	os.symlink(assets_rel_path, fmt.tprintf("%s/%s", out_dir, file)) or_return

	return exe, nil
}

// UTILS

process_exists :: proc(name: string, loc := #caller_location) -> bool {
	when ODIN_OS == .Windows {
		// 	call = 'TASKLIST', '/NH', '/FI', 'imagename eq %s' % process_name
		// 	return process_name in str(subprocess.check_output(call))
		panic("impement windows version for process_exists")
	} else when ODIN_OS == .Linux || ODIN_OS == .Darwin {
		cmd := []string{"bash", "-c", fmt.tprintf("pgrep -f %s", name)}
		_, stdout, _, err := os.process_exec({command = cmd}, context.temp_allocator)
		if err != nil {
			panic(fmt.tprintf("%v: %v", loc, err), loc)
		}

		return string(stdout) != ""
	}

	return false
}

append_exe_build_args :: proc(cmd: ^[dynamic]string, args: ^Args) {
	if !args.debug {
		append(cmd, "-no-bounds-check", "-o:speed")
		when ODIN_OS == .Windows {
			append(cmd, " -subsystem:windows")
		}
	} else {
		append(cmd, "-debug")
	}

	if args.gl {
		append(cmd, "-define:SOKOL_USE_GL=true")
	}
}

@(require_results)
get_shader_compiler :: proc() -> string {
	path := ""

	when ODIN_OS == .Windows {
		path = fmt.tprintf("%s\\win32\\sokol-shdc.exe", SOKOL_SHDC_PATH)
	} else when ODIN_OS == .Linux {
		when ODIN_ARCH == .arm64 {
			path = fmt.tprintf("%s/linux_arm64/sokol-shdc", SOKOL_SHDC_PATH)
		} else {
			path = fmt.tprintf("%s/linux/sokol-shdc", SOKOL_SHDC_PATH)
		}
	} else when ODIN_OS == .Darwin {
		when ODIN_ARCH == .arm64 {
			path = fmt.tprintf("%s/osx_arm64/sokol-shdc", SOKOL_SHDC_PATH)
		} else {
			path = fmt.tprintf("%s/osx/sokol-shdc", SOKOL_SHDC_PATH)
		}
	}

	return path
}

@(require_results)
get_emscripten_env_command :: proc(emsdk_path: string) -> (out: string, err: os.Error) {
	if emsdk_path == "" {
		return "", nil
	}

	when ODIN_OS == .Windows {
		path := os.join_path(
			[]string{emsdk_path, "emsdk_env.bat"},
			context.temp_allocator,
		) or_return
		if !os.exists(path) {
			return "", .Not_Exist
		}
		return path, nil
	} else when ODIN_OS == .Linux || ODIN_OS == .Darwin {
		path := os.join_path(
			[]string{emsdk_path, "emsdk_env.sh"},
			context.temp_allocator,
		) or_return
		if !os.exists(path) {
			return "", .Not_Exist
		}
		output := fmt.tprintf("source %s", path)

		return output, nil
	}

	return "", nil
}

@(require_results)
mkdir :: proc(name: string) -> os.Error {
	if os.exists(name) {
		return nil
	}

	os.mkdir_all(name) or_return

	return nil
}


@(require_results)
which :: proc(name: string, loc := #caller_location) -> string {
	cmd := []string{"bash", "-c", fmt.tprintf("which %s", name)}
	_, stdout, _, err := os.process_exec({command = cmd}, context.temp_allocator)
	if err != nil {
		panic(fmt.tprintf("%v: %v", loc, err), loc)
	}

	return string(stdout)
}

@(require_results)
execute2 :: proc(input: string, args: ..any) -> os.Error {
	cmd := fmt.tprintf(input, ..args)

	when ODIN_OS == .Windows {
		execute_cmd([]string{cmd}) or_return
	} else when ODIN_OS == .Linux || ODIN_OS == .Darwin {
		execute_cmd([]string{"bash", "-c", cmd}) or_return
	}

	return nil
}

// execute :: proc(input: string, args: ..any) -> os.Error {
// 	cmd := fmt.tprintf(input, ..args)
// 	execute_(cmd) or_return
//
// 	return nil
// }
//
// execute_ :: proc(input: string) -> (err: os.Error) {
// 	cmd := strings.split(input, " ")
// 	execute_cmd(cmd) or_return
// 	return nil
// }

@(require_results)
execute_cmd :: proc(cmd: []string) -> (err: os.Error) {
	fmt.printfln("Executing: %s", strings.join(cmd, " "))

	read_pipe, write_pipe, err_pipe := os.pipe()
	if err_pipe != nil {
		fmt.eprintln("Failed to create pipe:", err_pipe)
		return
	}


	desc := os.Process_Desc {
		command = cmd,
		stdout  = write_pipe,
		stderr  = write_pipe,
	}

	process := os.process_start(desc) or_return
	// Close write ends of pipes after process starts - important!
	os.close(write_pipe)

	buffer: [4096]u8
	for {
		n, read_err := os.read(read_pipe, buffer[:])
		if n > 0 {
			os.write(os.stdout, buffer[:n])
		}
		if read_err != nil {
			break
		}
	}


	// Clean up
	if kill_err := os.process_kill(process); kill_err != nil {
		fmt.eprintln("Failed to kill process:", kill_err)
	}

	if close_err := os.process_close(process); close_err != nil {
		fmt.eprintln("Failed to close process:", close_err)
	}


	process_state := os.process_wait(process) or_return
	if !process_state.success {
		fmt.println("Unsuccess process", "code", process_state.exit_code)
		return .Closed
	}

	return nil
}


@(require_results)
download :: proc(url: string, output_path: string) -> os.Error {
	execute2("curl -# -L -o %s %s", output_path, url) or_return

	return nil
}


@(require_results)
download_extract :: proc(url: string, output_path: string, archive_path := "") -> os.Error {
	mkdir(output_path) or_return
	assert(archive_path != "", "archive_path must be provided")

	curl_string :: "curl -# -L %s"
	cmd_string: string
	when ODIN_OS == .Windows {
		panic("implement download_extract")
	} else when ODIN_OS == .Linux {
		cmd_string = curl_string + " | tar --strip-components=2 --wildcards -xzv -C %s %s"
	} else when ODIN_OS == .Darwin {
		cmd_string = curl_string + " | tar --strip-components=2 -xv -C %s %s"
	}


	cmd := fmt.tprintf(cmd_string, url, output_path, archive_path)
	fmt.printfln("Downloading: %s", cmd)
	execute2(cmd) or_return

	return nil
}

@(require_results)
must :: proc(value: $T, err: $T2, loc := #caller_location) -> T {
	if err != nil {
		panic(fmt.tprintf("%v: %v", loc, err), loc)
	}
	return value
}


@(require_results)
delete_dir :: proc(name: string) -> os.Error {
	execute_cmd([]string{"bash", "-c", fmt.tprintf("rm -rf %s", name)}) or_return

	return nil
}
