# Odin + Sokol + Hot Reload template

Hot reload gameplay code when making games using Odin + Sokol.
Also comes with web build support
(no hot reload on web, it's just for web release builds).

Supported platforms: Windows, Linux and Mac.
It's possible to do the web build from all of them.

![ezgif-660dd8cd5add20](https://github.com/user-attachments/assets/676b48f0-74e3-4ffa-9098-a9956510aacb)

Demo and technical overview [video](https://www.youtube.com/watch?v=0wNjfgZlDyw)

## Requirements

- [Odin compiler](https://odin-lang.org/) (must be in PATH)
- [Emscripten](https://emscripten.org/) (optional, for web build support)

## Setup

Run `odin run . -- -sokol-update`.
It will download the Sokol bindings and try to build the Sokol C libraries.
It also downloads the Sokol Shader compiler.

The above may fail if no C compiler is available.
For example, on Windows you may need to use
the `x64 Native Tools Command Prompt for VS20XX`.
You can re-run the compilation using `odin run . -- -sokol-compile`.
This will avoid re-downloading Sokol, which `-sokol-update` does.

> [!NOTE]
> `-sokol-update` always does `-sokol-compile` automatically.
> [!WARNING]
> `-sokol-update` deletes the `sokol-shdc` and `src/game/sokol` directories.

If you want web build support,
then you either need `emcc` in your path
_or_ you can point to the emscripten
installation directory by adding `-emsdk-path path/to/emscripten`.
You'll have to run `-sokol-compile` with these things present
for it to compile the web (WASM) Sokol libraries.

## Hot reloading

1. Make sure you've done the [setup](#setup)
2. Run `odin run . -- -hot -run`
3. A game with just a spinning cube should start
4. Leave the game running, change a some line in
  `src/game/game.odin`. For example, you can modify the line `g.rx += 60 * dt`
  to use the value `500` instead of `60`.
5. Re-run `odin run . -- -hot -run`.
  The game DLL will re-compile and get reloaded. The cube will spin faster.

> [!NOTE]
> It doesn't matter if you use `-run` on step 5).
> If the hot reload executable is already running,
> then it won't try to re-start it.
> It will just re-build the game DLL and reload that.

## Web build

1. Make sure you've done the [setup](#setup).
  Pay attention to the stuff about `emcc` and `-emsdk-path`.
2. Run `odin run . -- -web`. You may also need to add `-emsdk-path path/to/emscripten`.
3. Web build is in `build/web`

> [!NOTE]
> You may not be able to start the `index.html` in there due to javascript CORS errors.
> If you run the game from a local web server then it will work:
>
> - Navigate to `build/web` in a terminal
> - Run `python -m http.server`
> - Go to `localhost:8000` in a browser to play your game.

Check the web developer tools console for any additional errors.
Chrome tends to have better error messages than Firefox.

## Native release builds

`odin run . -- -release` makes a native release build of your game (no hot reloading).

## Debugging

Add `-debug` when running `odin run . --` to create debuggable binaries.

## Updating Sokol

`odin run . -- -sokol-update` downloads the lastest Odin Sokol bindings
and latest Sokol shader compiler.

> [!WARNING]
> This will completely replace everything
> in the `sokol-shdc` and `src/game` directories.

`odin run . -- -sokol-compile` recompiles the sokol C and WASM libraries.

> [!NOTE]
> `-sokol-update` automatically does `-sokol-compile`.
> You can also add `-sokol-update` or `-sokol-compile` when building the game.
> For example you can do `odin run . -- -hot -sokol-update`
> to update Sokol before compiling the hot reload executable.

## Common issues

### The build script crashes due to missing libraries

- Make sure you're using a terminal that has access to a C compiler.
- Re-run `odin run . -- -sokol-compile`. If you want web (WASM) support,
  then make sure to have `emcc` in the PATH
  or use `-emsdk-path path/to/emscripten` to point out your emscripten installation.

### I'm on an old mac with no metal support

- Add `-gl` when running `build` to force OpenGL
- Remove the `set -e` lines from `src/game/build_clibs_macos.sh`
  and `src/game/build_clibs_macos_dylib.sh`
  and re-run `odin run . --  -sokol-compile`.
  This will make those scripts not crash when it fails
  to compile some metal-related Sokol libraries.

### I get `panic: wasm_allocator: initial memory could not be allocated`

You probably have a global variable that allocates dynamic memory.
Move that allocation into the `game_init` proc.
This could also happen if initialize dynamic arrays
or maps in the global file scope, like so:

```odin
arr := [dynamic]int { 2, 3, 4 }
```

In that case you can declare it and do the initialization in the `init` proc instead:

```odin
arr: [dynamic]int

main :: proc() {
  arr = { 2, 3, 4 }

  // bla bla
}
```

This happens because the context hasn't been initialized
with the correct allocator yet.

### I get `RuntimeError: memory access out of bounds`

Try modifying the `build.odin` script and add these flags where it runs `emcc`:

```text
-sALLOW_MEMORY_GROWTH=1 -sINITIAL_HEAP=16777216 -sSTACK_SIZE=65536
```

The numbers above are the default values, try bigger ones and see if it helps.

### Error: `emcc: error: build\web\index.data --from-emcc --preload assets' failed (returned 1)`

You might be missing the `assets` folder.
It must have at least a single file inside it.
You can also remove `--preload assets` from the `build` script.
