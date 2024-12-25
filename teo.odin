package teo

//Following along with https://viewsourcecode.org/snaptoken/kilo/index.html
//but doing it in odin instead of C. I think the concepts and steps should be
//generally the same I just need to figure out how to do it in Odin instead
//of just doing it in C like the url does

import "core:c/libc"
import "core:fmt"
import "core:io"
import "core:os"
import "core:sys/posix"
import "base:runtime"

main :: proc() {
	enable_raw_mode()

	buf := make([dynamic]byte)
	defer delete(buf)

	input_stream := os.stream_from_handle(os.stdin)

	for {
		char, err := io.read_byte(input_stream)
		switch {
		case err != nil:
			fmt.eprintf("\nError: %v\r\n", err)
			os.exit(1)
		case char == 'q':
			os.exit(0)
		case bool(libc.iscntrl(i32(char))):
			fmt.printf("%d\r\n", char)
		case:
			fmt.printf("%v\r\n", rune(char))
		}
	}
}

// setting up terminal

orig_term_mode: posix.termios

enable_raw_mode :: proc() {
	res := posix.tcgetattr(posix.STDIN_FILENO, &orig_term_mode)
	fmt.assertf(res == .OK, "did you change stdin to being a pipe or a file?")

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
	assert(res == .OK)
}

disable_raw_mode :: proc "c" () {
	context = runtime.default_context()

	res := posix.tcsetattr(posix.STDIN_FILENO, .TCSAFLUSH, &orig_term_mode)
	fmt.assertf(
		res == .OK,
		"failed setting term back to defaults... no idea what would have caused this so good luck",
	)

}
