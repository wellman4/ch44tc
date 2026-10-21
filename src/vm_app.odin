package main

import "base:runtime"
import "core:os"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"
import "core:path/filepath"

import "vendor:sdl3"
import "vendor:sdl3/ttf"

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
	opts:                  ^Vm_Options,
	window:                ^sdl3.Window,
	window_size:           [2]i32,
	canvas:                ^sdl3.Texture,
	canvas_dest:           sdl3.FRect,
	renderer:              ^sdl3.Renderer,
	font:                  ^ttf.Font,
	char_height:           f32,
	text_engine:           ^ttf.TextEngine,
	translation_allocator: mem.Allocator,
	vm:                    ch44vm.Vm,
	dbg_ctx:               Dbg_Context,
	key_map:               map[sdl3.Scancode]u8,
	target_frame_time:     u64,
	last_time:             u64,
	cpu_timer:             utils.Timer,
	chip8_60hz_timer:      utils.Timer,
	audio_device:          sdl3.AudioDeviceID,
	audio_stream:          ^sdl3.AudioStream,
	audio_sample_id:       u32,
	audio_frequency:       f32,
	audio_sample_rate:     f32,
	audio_volume:          f32,
}

Dbg_Context :: struct {
	is_enabled: bool,
	is_paused: bool,
	disasm_ctx: ch44sm.Disasm_Context,
	lines: [dynamic]^ttf.Text,
	register_texts: [20]^ttf.Text,
	scroll_y: f32,
}

run_vm_app :: proc(
	opts: ^Options,
	translation_allocator: mem.Allocator,
) {
	app_ctx := new(Vm_App_Context)
	defer free(app_ctx)

	opts := (^Vm_Options)(opts)
	app_ctx.opts = opts
	app_ctx.translation_allocator = translation_allocator

	if !app_init(app_ctx) do return
	app_mainloop(app_ctx)
	app_quit(app_ctx)
}

@(private="file")
app_init :: proc(app_ctx: ^Vm_App_Context) -> (ok: bool) {
	src, err := os.read_entire_file_from_path(app_ctx.opts.src_path, context.allocator)
	if err != nil {
		fmt.eprintfln("Error: failed to read source file at '%s'. Reason: %v", app_ctx.opts.src_path, err)
		return
	}
	defer delete(src)

	ch44vm.init(
		&app_ctx.vm,
		app_ctx.opts.platform,
		app_ctx.opts.quirks,
		app_ctx.opts.no_font,
		app_ctx.opts.org,
	)

	bytecode: []u8 = src

	switch filepath.ext(app_ctx.opts.src_path) {
	case ".ch8": ch44vm.load_bytes(&app_ctx.vm, bytecode, app_ctx.vm.pc) or_return
	case ".ch44sm":
		asm_ctx: ch44sm.Asm_Context
		asm_opts: Options = Asm_Options{src_path=app_ctx.opts.src_path}
		if !run_asm_app(&asm_opts, &asm_ctx, app_ctx.translation_allocator) do return
		bytecode = asm_ctx.bytecode[:]
		ch44vm.load_bytes(&app_ctx.vm, bytecode, app_ctx.vm.pc) or_return
	}

	if !sdl3.Init({.VIDEO, .AUDIO}) {
		fmt.eprintln(sdl3.GetError())
		return
	}

	window_flags: sdl3.WindowFlags = {.RESIZABLE}
	if app_ctx.opts.fullscreen {window_flags += {.FULLSCREEN}}
	if app_ctx.opts.maximized {window_flags += {.MAXIMIZED}}

	title_str: cstring = strings.clone_to_cstring(
		fmt.tprintf("Ch44vm: %s", app_ctx.opts.src_path),
		context.temp_allocator
	)
	app_ctx.window_size = {800, 600}
	app_ctx.window = sdl3.CreateWindow(title_str, app_ctx.window_size.x, app_ctx.window_size.y, window_flags)
	if app_ctx.window == nil {
		fmt.eprintln(sdl3.GetError())
		return
	}

	app_ctx.renderer = sdl3.CreateRenderer(app_ctx.window, nil)
	if app_ctx.renderer == nil {
		fmt.eprintln(sdl3.GetError())
		return
	}
	sdl3.SetRenderDrawBlendMode(app_ctx.renderer, {.BLEND})

	app_ctx.text_engine = ttf.CreateRendererTextEngine(app_ctx.renderer)

	app_ctx.canvas = sdl3.CreateTexture(
		app_ctx.renderer,
		.RGBA8888,
		.STREAMING,
		ch44vm.DISPLAY_WIDTH,
		ch44vm.DISPLAY_HEIGHT,
	)
	sdl3.SetTextureScaleMode(app_ctx.canvas, .NEAREST)

	app_ctx.canvas_dest = sdl3.FRect {
		x = 0.0,
		y = 0.0,
		w = f32(app_ctx.window_size.x),
		h = f32(app_ctx.window_size.y),
	}

	if !ttf.Init() {
		fmt.eprintfln("Error: failed to init ttf. Reason: %v", sdl3.GetError())
		return
	}

	font := ttf.OpenFont("assets/fonts/Source_Code_Pro/SourceCodePro-Regular.ttf", 16.0)
	if font == nil {
		fmt.eprintfln("Error: failed to open font. Reason: %v", sdl3.GetError())
		return
	}

	app_ctx.font = font
	char_height: i32 = ttf.GetFontHeight(font)
	app_ctx.char_height = f32(char_height)

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

	if app_ctx.opts.debug {
		app_ctx.dbg_ctx.is_enabled = true
		app_ctx.dbg_ctx.is_paused = true
		ch44sm.disasm_ctx_init(
			dctx = &app_ctx.dbg_ctx.disasm_ctx,
			src_path = app_ctx.opts.src_path,
			src = bytecode,
			org = app_ctx.opts.org,
			allocator = app_ctx.translation_allocator,
		)

		asm_source := ch44sm.disassemble(&app_ctx.dbg_ctx.disasm_ctx, app_ctx.translation_allocator)
		lines, err := strings.split_lines(asm_source, app_ctx.translation_allocator)
		for line_str in lines {
			txt_obj := ttf.CreateText(
				app_ctx.text_engine,
				app_ctx.font,
				([^]u8)(raw_data(line_str)),
				len(line_str)
			)
			append(&app_ctx.dbg_ctx.lines, txt_obj)
		}

		app_ctx.canvas_dest = sdl3.FRect {
			x = f32(app_ctx.window_size.x - 448),
			y = 0.0,
			w = 448.0,
			h = 224.0,
		}
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
			case .S: ch44vm.tick(&app_ctx.vm)
			case .GRAVE:
				if app_ctx.opts.debug do app_ctx.dbg_ctx.is_enabled = !app_ctx.dbg_ctx.is_enabled
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
	if !app_ctx.dbg_ctx.is_paused {
		utils.timer_update(&app_ctx.cpu_timer, dt)
	}

	if !app_ctx.opts.debug {
		utils.timer_update(&app_ctx.chip8_60hz_timer, dt)
		update_audio(app_ctx)
	}

	if app_ctx.dbg_ctx.is_enabled {
		app_ctx.canvas_dest = sdl3.FRect {
			x = f32(app_ctx.window_size.x - 448),
			y = 0.0,
			w = 448.0,
			h = 224.0,
		}
	} else {
		app_ctx.canvas_dest = sdl3.FRect {
			x = 0.0,
			y = 0.0,
			w = f32(app_ctx.window_size.x),
			h = f32(app_ctx.window_size.y),
		}
	}

	update_dbg_registers(app_ctx.text_engine, app_ctx.font, &app_ctx.dbg_ctx, &app_ctx.vm)

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

update_dbg_registers :: proc(engine: ^ttf.TextEngine, font: ^ttf.Font, ctx: ^Dbg_Context, vm: ^ch44vm.Vm) {
	buf: [64]byte

	update_reg_text :: proc(engine: ^ttf.TextEngine, font: ^ttf.Font, text_obj: ^^ttf.Text, str: string) {
		ptr := cast([^]u8)raw_data(str)
		length := uint(len(str))

		if text_obj^ == nil {
			text_obj^ = ttf.CreateText(engine, font, ptr, length)
		} else {
			ttf.SetTextString(text_obj^, ptr, length)
		}
	}

	for idx in 0..<16 {
		str := fmt.bprintf(buf[:], "v%x: 0x%02X", idx, vm.v[idx])
		update_reg_text(engine, font, &ctx.register_texts[idx], str)
	}

	str_pc := fmt.bprintf(buf[:], "pc: 0x%04X", vm.pc)
	update_reg_text(engine, font, &ctx.register_texts[16], str_pc)

	str_i := fmt.bprintf(buf[:], "i:  0x%04X", vm.i)
	update_reg_text(engine, font, &ctx.register_texts[17], str_i)

	str_dt := fmt.bprintf(buf[:], "dt: %3d", vm.delay_timer)
	update_reg_text(engine, font, &ctx.register_texts[18], str_dt)

	str_st := fmt.bprintf(buf[:], "st: %3d", vm.sound_timer)
	update_reg_text(engine, font, &ctx.register_texts[19], str_st)
}

@(private="file")
render :: #force_inline proc(app_ctx: ^Vm_App_Context) {
	sdl3.SetRenderDrawColor(app_ctx.renderer, 10, 10, 10, 255)
	sdl3.RenderClear(app_ctx.renderer)

	draw_asm_source(app_ctx)
	draw_dbg_registers(app_ctx, app_ctx.font)

	sdl3.RenderTexture(app_ctx.renderer, app_ctx.canvas, nil, &app_ctx.canvas_dest)
	sdl3.RenderPresent(app_ctx.renderer)
}

draw_asm_source :: proc(app_ctx: ^Vm_App_Context) {
	pc_idx := app_ctx.dbg_ctx.disasm_ctx.row_addrs[int(app_ctx.vm.pc)]
	target_line_y := f32(pc_idx) * app_ctx.char_height
	center_y := f32(app_ctx.window_size.y / 2) - (app_ctx.char_height / 2)
	app_ctx.dbg_ctx.scroll_y = target_line_y - center_y

	if app_ctx.dbg_ctx.scroll_y < 0 {
		app_ctx.dbg_ctx.scroll_y = 0
	}

	for txt_obj, idx in app_ctx.dbg_ctx.lines {
		line_y := (f32(idx) * app_ctx.char_height) - app_ctx.dbg_ctx.scroll_y

		if line_y + app_ctx.char_height < 0 || line_y > f32(app_ctx.window_size.y) {
			continue		
		}

		if app_ctx.dbg_ctx.scroll_y < 0 do app_ctx.dbg_ctx.scroll_y = 0

		if idx == pc_idx {
			sdl3.SetRenderDrawColor(app_ctx.renderer, 40, 145, 80, 55)

			highlight_rect := sdl3.FRect{
				x = 0,
				y = line_y,
				w = f32(app_ctx.window_size.x - 448),
				h = app_ctx.char_height,
			}

			sdl3.RenderFillRect(app_ctx.renderer, &highlight_rect)
		}
		
		ttf.DrawRendererText(txt_obj, 0, line_y)
	}
}

draw_dbg_registers :: proc(app_ctx: ^Vm_App_Context, font: ^ttf.Font) {
	start_x: f32 = app_ctx.canvas_dest.x
	start_y: f32 = app_ctx.canvas_dest.y + app_ctx.canvas_dest.h
		
	col_width: f32 = 120.0 

	for text_obj, idx in app_ctx.dbg_ctx.register_texts {
		if text_obj == nil do continue

		col_x: f32 = start_x
		line_y: f32 = start_y

		if idx < 16 {
			col_x = start_x
			line_y = start_y + (f32(idx) * app_ctx.char_height)
		} else if idx >= 17 && idx <= 19 {
			col_x = start_x + col_width
			line_y = start_y + (f32(idx - 17) * app_ctx.char_height)
		} else if idx == 16 {
			col_x = start_x + (col_width * 2)
			line_y = start_y
		}

		ttf.DrawRendererText(text_obj, col_x, line_y)
	}
}

@(private="file")
app_quit :: proc (app_ctx: ^Vm_App_Context) {
	if app_ctx != nil {
		ch44vm.destroy(&app_ctx.vm)
		delete(app_ctx.key_map)

		for txt in app_ctx.dbg_ctx.lines {
			ttf.DestroyText(txt)
		}

		for text_obj in app_ctx.dbg_ctx.register_texts {
			if text_obj != nil {
				ttf.DestroyText(text_obj)
			}
		}

		ttf.DestroyRendererTextEngine(app_ctx.text_engine)
		ttf.CloseFont(app_ctx.font)

		if app_ctx.renderer != nil do sdl3.DestroyRenderer(app_ctx.renderer)
		sdl3.DestroyTexture(app_ctx.canvas)
		if app_ctx.window != nil do sdl3.DestroyWindow(app_ctx.window)
		if app_ctx.audio_stream != nil do sdl3.DestroyAudioStream(app_ctx.audio_stream)
	}

	ttf.Quit()
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
