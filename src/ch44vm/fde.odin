package ch44vm

import "core:slice"
import "core:fmt"
import "core:math/rand"

import "../utils"

tick :: proc(v: ^Vm) {
	opcode := u16(v.mem[v.pc]) << 8 | u16(v.mem[v.pc + 1])
	v.pc += 2

	nnn := opcode & 0x0FFF
	nn  := u8(opcode & 0x00FF)
	n   := int(opcode & 0x000F)
	x   := int((opcode & 0x0F00) >> 8)
	y   := int((opcode & 0x00F0) >> 4)

	switch opcode & 0xF000 {
	case 0x0000:
		switch opcode & 0xFFF0 {
		case 0x00C0:
			scroll_amount := n
			if !v.is_high_res && .Vblank_Sync in v.quirks {
				scroll_amount = int(n) / 2
			}

			for y := v.display_size.y - 1; y >= scroll_amount; y -= 1 {
				for x in 0..<v.display_size.x {
					dest_idx := utils.get_idx(x, y, DISPLAY_WIDTH)
					src_idx := utils.get_idx(x, y - scroll_amount, DISPLAY_WIDTH)
					v.display[dest_idx] = v.display[src_idx]
				}
			}
			for y in 0..<scroll_amount {
				for x in 0..<v.display_size.x {
					v.display[utils.get_idx(x, y, DISPLAY_WIDTH)] = 0
				}
			}
			v.is_display_dirty = true
		case:
			switch opcode {
			case 0x00E0: 
				slice.zero(v.display[:])
				v.is_display_dirty = true
			case 0x00EE:
				if v.sp == 0 {
					fmt.eprintln("Stack is empty")
					return
				}
				v.sp -= 1
				v.pc = v.stack[v.sp]
			case 0x00FB:
				scroll_amount := !v.is_high_res && .Vblank_Sync in v.quirks ? 2 : 4
				for y in 0..<v.display_size.y {
					for x := v.display_size.x - 1; x >= scroll_amount; x -= 1 {
						v.display[utils.get_idx(x, y, DISPLAY_WIDTH)] = v.display[utils.get_idx(x - scroll_amount, y, DISPLAY_WIDTH)]
					}
					for x in 0..<scroll_amount {
						v.display[utils.get_idx(x, y, DISPLAY_WIDTH)] = 0
					}
				}
				v.is_display_dirty = true
			case 0x00FC:
				scroll_amount := !v.is_high_res && .Vblank_Sync in v.quirks ? 2 : 4
				for y in 0..<v.display_size.y {
					for x in 0..<(v.display_size.x - scroll_amount) {
						v.display[utils.get_idx(x, y, DISPLAY_WIDTH)] = v.display[utils.get_idx(x + scroll_amount, y, DISPLAY_WIDTH)]
					}
					for x := v.display_size.x - scroll_amount; x < v.display_size.x; x += 1 {
						v.display[utils.get_idx(x, y, DISPLAY_WIDTH)] = 0
					}
				}
				v.is_display_dirty = true
			case 0x00FD: v.status = .Exited
			case 0x00FE:
				v.is_high_res = false
				v.display_size = {64, 32}
				slice.zero(v.display[:])
				v.is_display_dirty = true
			case 0x00FF:
				v.is_high_res = true
				v.display_size = {128, 64}
				slice.zero(v.display[:])
				v.is_display_dirty = true
			}
		}      
	case 0x1000: v.pc = nnn
	case 0x2000:
		if int(v.sp) > len(v.stack) {
			fmt.eprintln("Stack Overflow")
			return
		}
		v.stack[v.sp] = v.pc
		v.sp += 1
	   	v.pc = nnn
	case 0x3000: if v.v[x] == nn do v.pc += 2
	case 0x4000: if v.v[x] != nn do v.pc += 2
	case 0x5000: if v.v[x] == v.v[y] do v.pc += 2
	case 0x6000: v.v[x] = nn
	case 0x7000: v.v[x] += nn
	case 0x8000:
		switch n {
		case 0x0: v.v[x] = v.v[y]
		case 0x1:
			v.v[x] |= v.v[y]
			if .Vf_Reset in v.quirks do v.v[0xF] = 0
		case 0x2:
			v.v[x] &= v.v[y]
			if .Vf_Reset in v.quirks do v.v[0xF] = 0
		case 0x3:
			v.v[x] ~= v.v[y]
			if .Vf_Reset in v.quirks do v.v[0xF] = 0
		case 0x4:
			result := u16(v.v[x]) + u16(v.v[y])
			v.v[x] = u8(result & 0xFF)
			v.v[0xF] = u8(1) if result > 255 else u8(0)
		case 0x5:
			vf := u8(1) if v.v[x] >= v.v[y] else u8(0)
			v.v[x] -= v.v[y]
			v.v[0xF] = vf
		case 0x6:
			if .Shift not_in v.quirks do v.v[x] = v.v[y]

			vf := v.v[x] & 0x01
			v.v[x] >>= 1
			v.v[0xF] = vf
		
		case 0x7:
			vf := u8(1) if v.v[y] >= v.v[x] else u8(0)
			v.v[x] = v.v[y] - v.v[x]
			v.v[0xF] = vf
		case 0xE:
			if .Shift not_in v.quirks do v.v[x] = v.v[y]

			vf := (v.v[x] >> 7) & 0x01
			v.v[x] <<= 1
			v.v[0xF] = vf
		case:
			fmt.printf("Unknown opcode 0x8000: 0x%X\n", opcode)
		}
	case 0x9000:
		if v.v[x] != v.v[y] {
			v.pc += 2
		}
	case 0xA000:
		v.i = nnn
	case 0xB000:
		v.pc = nnn + u16(v.v[.Jump_With_Offset in v.quirks ? x : 0])
	case 0xC000:
		v.v[x] = u8(rand.uint32() & 0xFF) & nn
	case 0xD000:
		start_x := int(v.v[x]) % v.display_size.x
		start_y := int(v.v[y]) % v.display_size.y
		v.v[0xF] = 0

		rows_count := n == 0 ? 16 : n
		cols_count := n == 0 ? 16 : 8        

		for row in 0..<rows_count {
			current_y := start_y + row
			if current_y >= v.display_size.y {
				if .Clipping in v.quirks {
					break
				} else {
					current_y %= v.display_size.y
				}
			}

			sprite_row_data: u16 = 0
			if n == 0 {
				addr := v.i + u16(row * 2)
				high_byte := u16(v.mem[addr])
				low_byte  := u16(v.mem[addr + 1])
				sprite_row_data = (high_byte << 8) | low_byte
			} else {
				sprite_row_data = u16(v.mem[v.i + u16(row)])
			}

			for col in 0..<cols_count {
				current_x := start_x + col
				if current_x >= v.display_size.x {
					if .Clipping in v.quirks {
						break
					} else {
						current_x %= v.display_size.x
					}
				}

				shift := u16((cols_count - 1) - col)
				sprite_pixel := (sprite_row_data >> shift) & 1
				if sprite_pixel == 1 {
					idx := utils.get_idx(current_x, current_y, DISPLAY_WIDTH)
			
					old_bit := v.display[idx]
					v.display[idx] ~= 1
					v.v[0xF] |= old_bit 
				}
			}
		}
		v.is_display_dirty = true
	case 0xE000:
		switch nn {
		case 0x9E:
			key_index := v.v[x] & 0x0F
			if v.keys[key_index] {
				v.pc += 2
			}
		case 0xA1:
			key_index := v.v[x] & 0x0F
			if !v.keys[key_index] {
				v.pc += 2
			}
		}
	case 0xF000:
		switch nn {
		case 0x07: v.v[x] = v.delay_timer
		case 0x0A:
			if !v.is_waiting_for_key_up {
				any_key_idx := -1
				for i in 0..<16 {
					if v.keys[i] {
						any_key_idx = i
						break
					}
				}

				if any_key_idx != -1 {
					v.is_waiting_for_key_up = true
					v.last_pressed_key = i8(any_key_idx)
				}
				
				v.pc -= 2
			} else {
				target_key := int(v.last_pressed_key)
				
				if v.keys[target_key] {
					v.pc -= 2
				} else {
					v.v[x] = u8(target_key)
					
					v.is_waiting_for_key_up = false
					v.last_pressed_key      = -1
				}
			}
		
		case 0x15: v.delay_timer = v.v[x]
		case 0x18: v.sound_timer = v.v[x]
		case 0x1E: v.i += u16(v.v[x])
		case 0x29: v.i = u16(v.v[x] & 0x0F) * 5
		case 0x30: v.i = 0x50 + u16(v.v[x] & 0x0F) * 10
		case 0x33:
			value := v.v[x]
			v.mem[v.i] = value / 100
			v.mem[v.i+ 1] = (value / 10) % 10
			v.mem[v.i+ 2] = value % 10
		case 0x55:
			for r in 0..=x {
				v.mem[v.i + u16(r)] = v.v[r]
			}
			if .Memory_Increment not_in v.quirks do v.i += u16(x) + 1
		case 0x65:
			for reg in 0..=x {
				v.v[reg] = v.mem[v.i + u16(reg)]
			}
			if .Memory_Increment not_in v.quirks do v.i += u16(x) + 1
		case 0x75:
			max_reg := x if x < 8 else 7
			for reg in 0..=max_reg {
				v.flags[reg] = v.v[reg]
			}
		case 0x85:
			max_reg := x if x < 8 else 7
			for reg in 0..=max_reg {
				v.v[reg] = v.flags[reg]
			}
		case:
			fmt.printf("Unknown opcode 0xF000: 0x%X\n", opcode)
		}
	case:
		fmt.printf("Unknown opcode: 0x%X\n", opcode)
	}
}

