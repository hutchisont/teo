package teo

//Following along with https://viewsourcecode.org/snaptoken/kilo/index.html
//but doing it in odin instead of C. I think the concepts and steps should be
//generally the same I just need to figure out how to do it in Odin instead
//of just doing it in C like the url does

import "base:runtime"
import "core:c/libc"
import "core:fmt"
import "core:io"
import "core:os"
import "core:sys/posix"

ctrl_key :: #force_inline proc(key: u8) -> u8 {
	return key & 0x1f
}

die :: proc(err: string) {
	clear_screen_and_reposition()
	fmt.eprintf(err)
}

main :: proc() {
	enable_raw_mode()

	for {
		editor_refresh_screen()
		editor_process_keypress()
	}
}

// setting up terminal

orig_term_mode: posix.termios

enable_raw_mode :: proc() {
	res := posix.tcgetattr(posix.STDIN_FILENO, &orig_term_mode)
	if res != .OK {
		die("failed to get terminal attributes, did you change stdin to being a pipe or a file?")
	}

	posix.atexit(disable_raw_mode)

	mode := orig_term_mode
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

	res := posix.tcsetattr(posix.STDIN_FILENO, .TCSAFLUSH, &orig_term_mode)
	if res != .OK {
		die("failed setting term back to defaults... no idea what would have caused this so good luck")
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
	for i in 0 ..< 24 {
		os.write(os.stdout, transmute([]u8)string("~\r\n"))
	}
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
