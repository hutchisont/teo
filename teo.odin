package teo

//Following along with https://viewsourcecode.org/snaptoken/kilo/index.html
//but doing it in odin instead of C. I think the concepts and steps should be
//generally the same I just need to figure out how to do it in Odin instead
//of just doing it in C like the url does

import "base:runtime"
import "core:c/libc"
import "core:c"
import "core:fmt"
import "core:io"
import "core:os"
import "core:sys/linux"
import "core:sys/posix"

Editor_Config :: struct {
	orig_term_mode: posix.termios,
	screen_rows:    int,
	screen_cols:    int,
}

config: Editor_Config

ctrl_key :: #force_inline proc(key: u8) -> u8 {
	return key & 0x1f
}

die :: proc(err: string) {
	clear_screen_and_reposition()
	fmt.printf(err, libc.errno())
	os.exit(1)
}

main :: proc() {
	enable_raw_mode()
	init_editor()

	for {
		editor_refresh_screen()
		editor_process_keypress()
	}
}

init_editor :: proc() {
	rows, cols, ok := get_window_size()
	if !ok {
		die("failed to get window size")
	}

	config.screen_rows = rows
	config.screen_cols = cols
}

// setting up terminal

enable_raw_mode :: proc() {
	res := posix.tcgetattr(posix.STDIN_FILENO, &config.orig_term_mode)
	if res != .OK {
		die("failed to get terminal attributes, did you change stdin to being a pipe or a file?")
	}

	posix.atexit(disable_raw_mode)

	mode := config.orig_term_mode
	mode.c_iflag -= {.ICRNL, .IXON, .BRKINT, .INPCK, .ISTRIP}
	mode.c_oflag -= {.OPOST}
	mode.c_cflag += {.CS8}
	mode.c_lflag -= {.ECHO, .ICANON, .IEXTEN, .ISIG}
	// don't think we need the below 2, part of the guide but don't have the same
	// read as c and it seems we block anyway... maybe less than ideal idk
	//mode.c_cc[.VMIN] = 0
	//mode.c_cc[.VTIME] = 1

	res = posix.tcsetattr(posix.STDIN_FILENO, .TCSAFLUSH, &mode)
	if res != .OK {
		die("failed to set terminal attributes... no idea why you're on your own")
	}
}

disable_raw_mode :: proc "c" () {
	context = runtime.default_context()

	res := posix.tcsetattr(posix.STDIN_FILENO, .TCSAFLUSH, &config.orig_term_mode)
	if res != .OK {
		die(
			"failed setting term back to defaults... no idea what would have caused this so good luck",
		)
	}
}

get_window_size :: proc() -> (row: int, col: int, ok: bool) {
	winsize :: struct {
		ws_row: c.ushort,
		ws_col: c.ushort,
		// according to https://linux.die.net/man/4/tty_ioctl these are actually unused
		ws_xpixel: c.ushort,
		ws_y_pixel: c.ushort,
	}

	ws := winsize{}

	TIOCGWINSZ :: 0x5413

	res := linux.ioctl(linux.Fd(os.stdout), TIOCGWINSZ, uintptr(&ws))
	if res != 0 {
		return
	} else if ws.ws_col == 0 {
		return
	} else {
		return int(ws.ws_row), int(ws.ws_col), true
	}
}

editor_process_keypress :: proc() {
	char := editor_read_key()
	switch {
	case char == ctrl_key('q'):
		clear_screen_and_reposition()
		os.exit(0)
	}
}

editor_read_key :: proc() -> u8 {
	buf := make([dynamic]byte)

	input_stream := os.stream_from_handle(os.stdin)

	char, err := io.read_byte(input_stream)
	switch {
	case err != nil:
		clear_screen_and_reposition()
		fmt.eprintf("\nError: %v\r\n", err)
		os.exit(1)
	}

	return char
}

editor_draw_rows :: proc() {
	for i in 0 ..< config.screen_rows - 1 {
		os.write(os.stdout, transmute([]u8)string("~\r\n"))
	}
	os.write(os.stdout, transmute([]u8)string("~"))
}

CLEAR_SCREEN :: "\x1b[2J"
SET_CURSOR_TO_TOP :: "\x1b[H"

clear_screen_and_reposition :: proc() {
	os.write(os.stdout, transmute([]u8)string(CLEAR_SCREEN))
	os.write(os.stdout, transmute([]u8)string(SET_CURSOR_TO_TOP))
}

editor_refresh_screen :: proc() {
	clear_screen_and_reposition()
	editor_draw_rows()

	os.write(os.stdout, transmute([]u8)string(SET_CURSOR_TO_TOP))
}
