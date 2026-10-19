package main

import "base:runtime"
import "core:os"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"
import "core:path/filepath"

import "vendor:sdl3"

import "utils"
import "ch44vm"
import "ch44sm"

@(rodata)
chip8_default_key_map := []sdl3.Scancode{
	0x0 = sdl3.Scancode.X,
	0x1 = sdl3.Scancode._1,
	0x2 = sdl3.Scancode._2,
	0x3 = sdl3.Scancode._3,
	0x4 = sdl3.Scancode.Q,
	0x5 = sdl3.Scancode.W,
	0x6 = sdl3.Scancode.E,
	0x7 = sdl3.Scancode.A,
	0x8 = sdl3.Scancode.S,
	0x9 = sdl3.Scancode.D,
	0xA = sdl3.Scancode.Z,
	0xB = sdl3.Scancode.C,
	0xC = sdl3.Scancode._4,
	0xD = sdl3.Scancode.R,
	0xE = sdl3.Scancode.F,
	0xF = sdl3.Scancode.V,
}

Vm_App_Context :: struct {
	opts:              ^Vm_Options,
	window:            ^sdl3.Window,
	canvas:            ^sdl3.Texture,
	renderer:          ^sdl3.Renderer,
	vm:                ch44vm.Vm,
	key_map:           map[sdl3.Scancode]u8,
	target_frame_time: u64,
	last_time:         u64,
	cpu_timer:         utils.Timer,
	chip8_60hz_timer:  utils.Timer,
	audio_device:      sdl3.AudioDeviceID,
	audio_stream:      ^sdl3.AudioStream,
	audio_sample_id:   u32,
	audio_frequency:   f32,
	audio_sample_rate: f32,
	audio_volume:      f32,
}

run_vm_app :: proc(opts: ^Options, translation_allocator: mem.Allocator) {
	app_ctx := new(Vm_App_Context)
	defer free(app_ctx)

	opts := (^Vm_Options)(opts)
	app_ctx.opts = opts

	if !app_init(app_ctx, translation_allocator) do return
	app_mainloop(app_ctx)
	app_quit(app_ctx)
}

@(private="file")
app_init :: proc(app_ctx: ^Vm_App_Context, translation_allocator: mem.Allocator) -> (ok: bool) {
	if !sdl3.Init({.VIDEO, .AUDIO}) {
		fmt.eprintln(sdl3.GetError())
		return
	}

	src, err := os.read_entire_file_from_path(app_ctx.opts.src_path, context.allocator)
	if err != nil {
		fmt.eprintfln("Error: failed to read source file at '%s'. Reason: %v", app_ctx.opts.src_path, err)
		return
	}
	defer delete(src)

	ch44vm.init(&app_ctx.vm, app_ctx.opts.platform, app_ctx.opts.quirks, app_ctx.opts.no_font)

	switch filepath.ext(app_ctx.opts.src_path) {
	case ".ch8": ch44vm.load_bytes(&app_ctx.vm, src, app_ctx.vm.pc) or_return
	case ".ch44sm":
		asm_ctx: ch44sm.Asm_Context
		asm_opts: Options = Asm_Options{src_path=app_ctx.opts.src_path}
		if !run_asm_app(&asm_opts, &asm_ctx, translation_allocator) do return
		ch44vm.load_bytes(&app_ctx.vm, asm_ctx.bytecode[:], app_ctx.vm.pc) or_return
	}

	window_flags: sdl3.WindowFlags = {.RESIZABLE}
	if app_ctx.opts.fullscreen {window_flags += {.FULLSCREEN}}
	if app_ctx.opts.maximized {window_flags += {.MAXIMIZED}}

	title_str: cstring = strings.clone_to_cstring(
		fmt.tprintf("Ch44vm: %s", app_ctx.opts.src_path),
		context.temp_allocator
	)
	app_ctx.window = sdl3.CreateWindow(title_str, 800, 600, window_flags)
	if app_ctx.window == nil {
		fmt.eprintln(sdl3.GetError())
		return
	}

	app_ctx.renderer = sdl3.CreateRenderer(app_ctx.window, nil)
	if app_ctx.renderer == nil {
		fmt.eprintln(sdl3.GetError())
		return
	}

	app_ctx.canvas = sdl3.CreateTexture(
		app_ctx.renderer,
		.RGBA8888,
		.STREAMING,
		ch44vm.DISPLAY_WIDTH,
		ch44vm.DISPLAY_HEIGHT,
	)
	sdl3.SetTextureScaleMode(app_ctx.canvas, .NEAREST)

	app_ctx.last_time = sdl3.GetTicksNS()
	app_ctx.target_frame_time = 1_000_000_000 / u64(app_ctx.opts.target_fps)

	utils.timer_init(
		&app_ctx.cpu_timer,
		1.0 / f64(app_ctx.opts.tick_rate),
		utils.Timer_Mode.Loop,
		on_cpu_tick,
		app_ctx,
	)
	utils.timer_init(
		&app_ctx.chip8_60hz_timer,
		1.0 / 60.0,
		utils.Timer_Mode.Loop,
		on_chip8_hardware_tick,
		rawptr(app_ctx)
	)

	if len(app_ctx.opts.colors) == 0{
		append(&app_ctx.opts.colors, u32(0x000000FF), u32(0xFFFFFFFF))
	}
	if len(app_ctx.opts.keys) == 0 {
		append(&app_ctx.opts.keys, ..chip8_default_key_map)
	}

	for i in u8(0) ..< 16 {
		user_scancode := sdl3.Scancode(app_ctx.opts.keys[i])
		app_ctx.key_map[user_scancode] = i
	}

	app_ctx.audio_frequency = f32(440.0)
	app_ctx.audio_sample_rate = f32(44100.0)
	app_ctx.audio_volume = 0.14 * app_ctx.opts.volume

	spec := sdl3.AudioSpec {
		format   = .F32,
		channels = 1,
		freq     = 44100,
	}

	app_ctx.audio_device = sdl3.AUDIO_DEVICE_DEFAULT_PLAYBACK
	app_ctx.audio_stream = sdl3.OpenAudioDeviceStream(app_ctx.audio_device, &spec, nil, nil)

	if app_ctx.audio_stream == nil {
		fmt.eprintln(
			sdl3.GetError(),
		)
	} else {
		sdl3.ResumeAudioStreamDevice(app_ctx.audio_stream)
	}

	return true
}

@(private="file")
app_mainloop :: proc (app_ctx: ^Vm_App_Context) {
	for {
		frame_start_time := sdl3.GetTicksNS()
		dt := f64(frame_start_time - app_ctx.last_time) / 1_000_000_000.0
		app_ctx.last_time = frame_start_time

		if !handle_events(app_ctx) do return
		if !update(app_ctx, dt) do return 
		render(app_ctx)
		free_all(context.temp_allocator)

		frame_end_time := sdl3.GetTicksNS()
		frame_time := frame_end_time - frame_start_time
		if frame_time < app_ctx.target_frame_time {
			sdl3.DelayPrecise(app_ctx.target_frame_time - frame_time)
		}
	}
}

@(private="file")
handle_events :: #force_inline proc (app_ctx: ^Vm_App_Context) -> (advance := true) {
	event: sdl3.Event = ---
	for sdl3.PollEvent(&event) {
		#partial switch event.type {
		case .QUIT:
			return false
		case .KEY_DOWN:
			#partial switch event.key.scancode {
			case .ESCAPE:
				return false
			}

			if chip8_key, ok := app_ctx.key_map[event.key.scancode]; ok {
				app_ctx.vm.keys[chip8_key] = true
			}
		case .KEY_UP:
			if chip8_key, ok := app_ctx.key_map[event.key.scancode]; ok {
				app_ctx.vm.keys[chip8_key] = false
			}
		}
	}
	return true
}

@(private="file")
update :: #force_inline proc (app_ctx: ^Vm_App_Context, dt: f64) -> (advance := true) {
	utils.timer_update(&app_ctx.cpu_timer, dt)
	utils.timer_update(&app_ctx.chip8_60hz_timer, dt)
	update_audio(app_ctx)

	if app_ctx.vm.status == .Exited do return false

	if app_ctx.vm.is_display_dirty {
		rgba_buffer: [ch44vm.DISPLAY_WIDTH * ch44vm.DISPLAY_HEIGHT]u32

		if app_ctx.vm.is_high_res {
			for y in 0 ..< 64 {
				for x in 0 ..< 128 {
					idx := utils.get_idx(x, y, ch44vm.DISPLAY_WIDTH)
					pixel := app_ctx.vm.display[idx]
					rgba_buffer[idx] =
						pixel == 1 ? app_ctx.opts.colors[1] : app_ctx.opts.colors[0]
				}
			}
		} else {
			for y in 0 ..< 32 {
				for x in 0 ..< 64 {
					pixel := app_ctx.vm.display[utils.get_idx(x, y, ch44vm.DISPLAY_WIDTH)]
					color :=
						pixel == 1 ? app_ctx.opts.colors[1] : app_ctx.opts.colors[0]

					tx := x * 2
					ty := y * 2

					rgba_buffer[(ty + 0) * 128 + (tx + 0)] = color
					rgba_buffer[(ty + 0) * 128 + (tx + 1)] = color
					rgba_buffer[(ty + 1) * 128 + (tx + 0)] = color
					rgba_buffer[(ty + 1) * 128 + (tx + 1)] = color
				}
			}
		}

		pitch := i32(ch44vm.DISPLAY_WIDTH * size_of(u32))
		sdl3.UpdateTexture(app_ctx.canvas, nil, raw_data(&rgba_buffer), pitch)

		app_ctx.vm.is_display_dirty = false
	}
	return true
}

@(private="file")
render :: #force_inline proc(app_ctx: ^Vm_App_Context) {
	sdl3.SetRenderDrawColor(app_ctx.renderer, 0, 0, 0, 255)
	sdl3.RenderClear(app_ctx.renderer)
	sdl3.RenderTexture(app_ctx.renderer, app_ctx.canvas, nil, nil)
	sdl3.RenderPresent(app_ctx.renderer)
}

@(private="file")
app_quit :: proc (app_ctx: ^Vm_App_Context) {
	if app_ctx != nil {
		ch44vm.destroy(&app_ctx.vm)
		delete(app_ctx.key_map)
		if app_ctx.renderer != nil do sdl3.DestroyRenderer(app_ctx.renderer)
		sdl3.DestroyTexture(app_ctx.canvas)
		if app_ctx.window != nil do sdl3.DestroyWindow(app_ctx.window)
		if app_ctx.audio_stream != nil do sdl3.DestroyAudioStream(app_ctx.audio_stream)
	}

	sdl3.Quit()
}

@(private="file")
on_cpu_tick :: proc(user_data: rawptr) {
	app_ctx := cast(^Vm_App_Context)user_data

	ch44vm.tick(&app_ctx.vm)

	if .Vblank_Sync in app_ctx.vm.quirks && app_ctx.vm.is_display_dirty && !app_ctx.vm.is_high_res {
		utils.timer_reset(&app_ctx.cpu_timer)
	}
}

@(private="file")
on_chip8_hardware_tick :: proc(user_data: rawptr) {
	app_ctx := cast(^Vm_App_Context)user_data

	if app_ctx.vm.delay_timer > 0 do app_ctx.vm.delay_timer -= 1
	if app_ctx.vm.sound_timer > 0 do app_ctx.vm.sound_timer -= 1
}

@(private="file")
update_audio :: proc(app_ctx: ^Vm_App_Context) {
	if app_ctx.audio_stream == nil || app_ctx.opts.mute {
		if app_ctx.audio_stream != nil && sdl3.GetAudioStreamQueued(app_ctx.audio_stream) > 0 {
			sdl3.ClearAudioStream(app_ctx.audio_stream)
			app_ctx.audio_sample_id = 0
		}
		return
	}

	queued_bytes := sdl3.GetAudioStreamQueued(app_ctx.audio_stream)
	queued_samples := queued_bytes / size_of(f32)

	if app_ctx.vm.sound_timer > 0 {
		TARGET_QUEUE :: 2500

		if queued_samples < TARGET_QUEUE {
			needed_samples := TARGET_QUEUE - queued_samples

			buffer := make([]f32, needed_samples, context.temp_allocator)
			samples_per_cycle := app_ctx.audio_sample_rate / app_ctx.audio_frequency
			
			for i in 0 ..< needed_samples {
				phase := f32(app_ctx.audio_sample_id) / samples_per_cycle

				app_ctx.audio_sample_id += 1
				if f32(app_ctx.audio_sample_id) >= samples_per_cycle {
					app_ctx.audio_sample_id = 0
				}

				buffer[i] = app_ctx.audio_volume if phase < 0.5 else -app_ctx.audio_volume
			}

			data_size := u32(len(buffer) * size_of(f32))
			sdl3.PutAudioStreamData(app_ctx.audio_stream, raw_data(buffer), i32(data_size))
		}
	} else {
		if queued_samples > 0 {
			sdl3.ClearAudioStream(app_ctx.audio_stream)
			app_ctx.audio_sample_id = 0
		}
	}
}
