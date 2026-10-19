package utils

Timer_Mode :: enum {
	One_Shot,
	Loop,
}

Timer_Callback :: proc(user_data: rawptr)

Timer :: struct {
    target_time: f64,
    accumulator: f64,
    mode:        Timer_Mode,
    is_active:   bool,    
    callback:    Timer_Callback,
    user_data:   rawptr,
}

timer_init :: proc(
	t: ^Timer,
	target_time: f64,
	mode: Timer_Mode,
	callback: Timer_Callback,
	user_data: rawptr
) {
    t.target_time = target_time
    t.accumulator = 0.0
    t.mode        = mode
    t.is_active   = true
    t.callback    = callback
    t.user_data   = user_data
}

timer_update :: proc(t: ^Timer, dt: f64) {
    if !t.is_active do return

    t.accumulator += dt

    for t.accumulator >= t.target_time {
        if t.callback != nil {
            t.callback(t.user_data)
        }

        switch t.mode {
        case .One_Shot:
            t.accumulator = 0.0
            t.is_active = false
            return            

        case .Loop:
            t.accumulator -= t.target_time
        }
    }
}

timer_reset :: #force_inline proc(t: ^Timer) {
	t.accumulator = 0.0
}
