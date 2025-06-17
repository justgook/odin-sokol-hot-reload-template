/*
Development game exe. Loads build/hot_reload/game.dll and reloads it whenever it
changes.

Uses sokol/app to open the window. The init, frame, event and cleanup callbacks
of the app run procedures inside the current game DLL.
*/

package main

import "base:runtime"
import "core:dynlib"
import "core:fmt"
import "core:log"
import "core:mem"
import os "core:os/os2"
import "core:strings"
import "core:time"

import sapp "../../game/sokol/app"


Game_API :: struct {
	lib:               dynlib.Library,
	app_default_desc:  proc() -> sapp.Desc,
	init:              proc(),
	frame:             proc(),
	event:             proc(e: ^sapp.Event),
	cleanup:           proc(),
	memory:            proc() -> rawptr,
	memory_size:       proc() -> int,
	hot_reloaded:      proc(mem: rawptr),
	force_restart:     proc() -> bool,
	modification_time: time.Time,
	dll_path:          string,
	api_version:       int,
}

DLL_FILE :: #config(DLL_FILE, "game_hot.dylib")

get_game_dll_path :: proc() -> (dll_path, dll_tmp_path: string, err: os.Error) {
	current_dir := os.get_executable_directory(context.allocator) or_return
	dll_path = os.join_path([]string{current_dir, DLL_FILE}, context.allocator) or_return

	tmp_dir := os.temp_dir(context.allocator) or_return
	base, ext := os.split_filename(DLL_FILE)

	tmp_file := fmt.tprintf(
		"{0}_{2}.{1}",
		os.split_filename(DLL_FILE),
		time.to_unix_nanoseconds(time.now()),
	)
	dll_tmp_path = os.join_path([]string{tmp_dir, tmp_file}, context.allocator) or_return

	return
}

load_game_api :: proc(api_version: int) -> (api: Game_API, err: os.Error) {
	dll_path, dll_tmp_path := get_game_dll_path() or_return
	fmt.printfln("LOADING API: %s", dll_tmp_path)

	mod_time := os.last_write_time_by_name(dll_path) or_return
	// if mod_time_error != os.ERROR_NONE {
	// 	fmt.printfln(
	// 		"Failed getting last write time of %s, error code: %s",
	// 		dll_path,
	// 		mod_time_error,
	// 	)
	//
	// 	return
	// }

	// game_dll_name := fmt.tprintf(GAME_DLL_DIR + "game_{0}" + DLL_EXT, api_version)
	// We copy the DLL because using it directly would lock it, which would prevent
	// the compiler from writing to it.
	os.copy_file(dll_tmp_path, dll_path) or_return


	// This proc matches the names of the fields in Game_API to symbols in the
	// game DLL. It actually looks for symbols starting with `game_`, which is
	// why the argument `"game_"` is there.
	_, ok := dynlib.initialize_symbols(&api, dll_tmp_path, "game_", "lib")
	if !ok {
		fmt.printfln("Failed initializing symbols: {0}", dynlib.last_error())
	}

	api.api_version = api_version
	api.modification_time = mod_time
	api.dll_path = dll_path

	return
}

unload_game_api :: proc(api: ^Game_API) {
	if api.lib != nil {
		if !dynlib.unload_library(api.lib) {
			fmt.printfln("Failed unloading lib: {0}", dynlib.last_error())
		}
	}
}

game_api: Game_API
game_api_version: int

custom_context: runtime.Context

init :: proc "c" () {
	context = custom_context
	game_api.init()
}

frame :: proc "c" () {
	context = custom_context
	game_api.frame()

	reload: bool
	game_dll_mod, game_dll_mod_err := os.last_write_time_by_name(game_api.dll_path)


	if game_dll_mod_err == os.ERROR_NONE && game_api.modification_time != game_dll_mod {
		reload = true
	}

	force_restart := game_api.force_restart()

	if reload || force_restart {
		new_game_api, new_game_api_ok := load_game_api(game_api_version)

		if new_game_api_ok == nil {
			force_restart = force_restart || game_api.memory_size() != new_game_api.memory_size()

			if !force_restart {
				// This does the normal hot reload

				// Note that we don't unload the old game APIs because that
				// would unload the DLL. The DLL can contain stored info
				// such as string literals. The old DLLs are only unloaded
				// on a full reset or on shutdown.
				append(&old_game_apis, game_api)
				game_memory := game_api.memory()
				game_api = new_game_api
				game_api.hot_reloaded(game_memory)
			} else {
				// This does a full reset. That's basically like opening and
				// closing the game, without having to restart the executable.
				//
				// You end up in here if the game requests a full reset OR
				// if the size of the game memory has changed. That would
				// probably lead to a crash anyways.

				game_api.cleanup()
				reset_tracking_allocator(&tracking_allocator)

				for &g in old_game_apis {
					unload_game_api(&g)
				}

				clear(&old_game_apis)
				unload_game_api(&game_api)
				game_api = new_game_api
				game_api.init()
			}

			game_api_version += 1
		}
	}
}

reset_tracking_allocator :: proc(a: ^mem.Tracking_Allocator) -> bool {
	err := false

	for _, value in a.allocation_map {
		fmt.printf("%v: Leaked %v bytes\n", value.location, value.size)
		err = true
	}

	mem.tracking_allocator_clear(a)
	return err
}

event :: proc "c" (e: ^sapp.Event) {
	context = custom_context
	game_api.event(e)
}

tracking_allocator: mem.Tracking_Allocator

cleanup :: proc "c" () {
	context = custom_context
	game_api.cleanup()
}

old_game_apis: [dynamic]Game_API

main :: proc() {
	if exe_dir, exe_dir_err := os.get_executable_directory(context.temp_allocator);
	   exe_dir_err == nil {
		os.set_working_directory(exe_dir)
	}

	context.logger = log.create_console_logger()

	default_allocator := context.allocator
	mem.tracking_allocator_init(&tracking_allocator, default_allocator)
	context.allocator = mem.tracking_allocator(&tracking_allocator)

	custom_context = context

	game_api_err: os.Error
	game_api, game_api_err = load_game_api(game_api_version)

	if game_api_err != nil {
		fmt.println("Failed to load Game API")
		return
	}

	game_api_version += 1
	old_game_apis = make([dynamic]Game_API, default_allocator)

	app_desc := game_api.app_default_desc()

	app_desc.init_cb = init
	app_desc.frame_cb = frame
	app_desc.cleanup_cb = cleanup
	app_desc.event_cb = event

	sapp.run(app_desc)

	free_all(context.temp_allocator)

	if reset_tracking_allocator(&tracking_allocator) {
		// You can add something here to inform the user that the program leaked
		// memory. In many cases a terminal window will close on shutdown so the
		// user could miss it.
	}

	for &g in old_game_apis {
		unload_game_api(&g)
	}

	delete(old_game_apis)

	unload_game_api(&game_api)
	mem.tracking_allocator_destroy(&tracking_allocator)
}

// Make game use good GPU on laptops.

@(export)
NvOptimusEnablement: u32 = 1

@(export)
AmdPowerXpressRequestHighPerformance: i32 = 1
