package utils

get_idx :: #force_inline proc(x, y, pitch: int) -> int {
    return y * pitch + x
}
