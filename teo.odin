package teo

//Following along with https://viewsourcecode.org/snaptoken/kilo/index.html
//but doing it in odin instead of C. I think the concepts and steps should be
//generally the same I just need to figure out how to do it in Odin instead
//of just doing it in C like the url does

import "base:runtime"
import "core:c"
import "core:c/libc"
import "core:fmt"
import "core:io"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"

VERSION :: "0.0.1"

// Terminal escape codes/commands
CLEAR_SCREEN :: "\x1b[2J"
CLEAR_CURRENT_LINE :: "\x1b[K"
SET_CURSOR_TO_TOP :: "\x1b[H"
SET_CURSOR_TO_LOCATION :: "\x1b[%d;%dH" // y, x
HIDE_CURSOR :: "\x1b[?25l"
SHOW_CURSOR :: "\x1b[?25h"

Editor_Row :: struct {
	data: []u8,
}

Editor_Config :: struct {
	cursor_x:       int,
	cursor_y:       int,
	row_offset:     int,
	screen_rows:    int,
	screen_cols:    int,
	rows:           [dynamic]Editor_Row,
	orig_term_mode: posix.termios,
}

Config: Editor_Config

Editor_Key :: enum {
	Arrow_Left = 1000,
	Arrow_Right,
	Arrow_Up,
	Arrow_Down,
	Del,
	Home,
	End,
	Page_Up,
	Page_Down,
}

ctrl_key :: #force_inline proc(key: u8) -> u8 {
	return key & 0x1f
}

die :: proc(err: string) {
	clear_screen_and_reposition_now()
	log.fatal(err, libc.errno())
}

main :: proc() {
	// setting this up is largely yanked from Karl's understanding the odin programming language book
	// https://odinbook.com/
	mode: int = 0
	when ODIN_OS == .Linux || ODIN_OS == .Darwin {
		mode = os.S_IRUSR | os.S_IWUSR | os.S_IRGRP | os.S_IROTH
	}

	logh, logh_err := os.open("log.txt", (os.O_CREATE | os.O_TRUNC | os.O_RDWR), mode)
	if logh_err != os.ERROR_NONE {
		fmt.eprintfln("Failed setting up log file")
		os.exit(1)
	}
	defer os.close(logh)

	context.logger = log.create_file_logger(logh, .Warning)
	defer log.destroy_file_logger(context.logger)

	enable_raw_mode()
	init_editor()

	args := os.args
	if len(args) >= 2 {
		editor_open(args[1])
	}

	for {
		free_all(context.temp_allocator)

		editor_refresh_screen()
		editor_process_keypress()
	}
}

init_editor :: proc() {
	rows, cols, ok := get_window_size()
	if !ok {
		die("failed to get window size")
	}
	Config.screen_rows = rows
	Config.screen_cols = cols
}

// setting up terminal

enable_raw_mode :: proc() {
	res := posix.tcgetattr(posix.STDIN_FILENO, &Config.orig_term_mode)
	if res != .OK {
		die("failed to get terminal attributes, did you change stdin to being a pipe or a file?")
	}

	posix.atexit(disable_raw_mode)

	mode := Config.orig_term_mode
	mode.c_iflag -= {.ICRNL, .IXON, .BRKINT, .INPCK, .ISTRIP}
	mode.c_oflag -= {.OPOST}
	mode.c_cflag += {.CS8}
	mode.c_lflag -= {.ECHO, .ICANON, .IEXTEN, .ISIG}
	mode.c_cc[.VMIN] = 0
	mode.c_cc[.VTIME] = 1

	res = posix.tcsetattr(posix.STDIN_FILENO, .TCSAFLUSH, &mode)
	if res != .OK {
		die("failed to set terminal attributes... no idea why you're on your own")
	}
}

disable_raw_mode :: proc "c" () {
	context = runtime.default_context()

	res := posix.tcsetattr(posix.STDIN_FILENO, .TCSAFLUSH, &Config.orig_term_mode)
	if res != .OK {
		die(
			"failed setting term back to defaults... no idea what would have caused this so good luck",
		)
	}
}

get_window_size :: proc() -> (row: int, col: int, ok: bool) {
	winsize :: struct {
		ws_row:     c.ushort,
		ws_col:     c.ushort,
		// according to https://linux.die.net/man/4/tty_ioctl these are actually unused
		ws_xpixel:  c.ushort,
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


// backing buffer for editor

eb_append :: proc {
	eb_append_slice,
	eb_append_string,
}

eb_append_slice :: proc(eb: ^[dynamic]u8, data: []u8) {
	if len(data) > Config.screen_cols {
		log.warn("truncating data to fit in column...\n data is: %v", data)
		append(eb, ..data[:Config.screen_cols])
	} else {
		append(eb, ..data)
	}
}

eb_append_string :: proc(eb: ^[dynamic]u8, data: string) {
	if len(data) > Config.screen_cols {
		log.warn("truncating data to fit in column...\n data is: %v", data)
		append(eb, ..transmute([]u8)data[:Config.screen_cols])
	} else {
		append(eb, ..transmute([]u8)data)
	}
}

editor_process_keypress :: proc() {
	char := editor_read_key()
	if int(char) == int(ctrl_key('q')) {
		clear_screen_and_reposition_now()
		os.exit(0)
	}

	switch Editor_Key(char) {

	case .Del:
	// do nothing for now

	case .Home:
		Config.cursor_x = 0
	case .End:
		Config.cursor_x = Config.screen_cols - 1

	case .Page_Up:
		for i := Config.screen_rows; i > 0; i -= 1 {
			editor_move_cursor(int(Editor_Key.Arrow_Up))
		}
	case .Page_Down:
		for i := Config.screen_rows; i > 0; i -= 1 {
			editor_move_cursor(int(Editor_Key.Arrow_Down))
		}

	case .Arrow_Up, .Arrow_Down, .Arrow_Left, .Arrow_Right:
		editor_move_cursor(char)
	}
}

editor_move_cursor :: proc(key: int) {
	#partial switch Editor_Key(key) {
	case .Arrow_Left:
		if Config.cursor_x != 0 {
			Config.cursor_x -= 1
		}
	case .Arrow_Right:
		if Config.cursor_x != Config.screen_cols - 1 {
			Config.cursor_x += 1
		}
	case .Arrow_Up:
		if Config.cursor_y != 0 {
			Config.cursor_y -= 1
		}
	case .Arrow_Down:
		if Config.cursor_y < len(Config.rows) {
			Config.cursor_y += 1
		}
	}
}

editor_read_key :: proc() -> int {
	buf := make([dynamic]byte)

	input_stream := os.stream_from_handle(os.stdin)

	c, err := io.read_byte(input_stream)
	char: int = int(c)
	if err != .None && err != .EOF {
		clear_screen_and_reposition_now()
		log.fatalf("Error: %v", err)
	}

	log.debugf("read byte: %c", char)

	ESCAPE_SEQUENCE: int : '\x1b'

	if char == ESCAPE_SEQUENCE {
		seq := [3]u8{}
		seq[0], err = io.read_byte(input_stream)
		if err != .None && err != .EOF {
			return ESCAPE_SEQUENCE
		}
		seq[1], err = io.read_byte(input_stream)
		if err != .None && err != .EOF {
			return ESCAPE_SEQUENCE
		}

		log.debugf("read 1st next: %c", seq[0])
		log.debugf("read 2nd next: %c", seq[1])

		if seq[0] == '[' {
			if seq[1] >= '0' && seq[1] <= '9' {
				seq[2], err = io.read_byte(input_stream)
				if err != .None && err != .EOF {
					return ESCAPE_SEQUENCE
				}
				log.debugf("read 3rd next: %c", seq[2])

				if seq[2] == '~' {
					switch seq[1] {
					case '3':
						return int(Editor_Key.Del)
					case '1', '7':
						return int(Editor_Key.Home)
					case '4', '8':
						return int(Editor_Key.End)
					case '5':
						return int(Editor_Key.Page_Up)
					case '6':
						return int(Editor_Key.Page_Down)
					}
				}

			} else {
				switch seq[1] {
				case 'A':
					return int(Editor_Key.Arrow_Up)
				case 'B':
					return int(Editor_Key.Arrow_Down)
				case 'C':
					return int(Editor_Key.Arrow_Right)
				case 'D':
					return int(Editor_Key.Arrow_Left)
				case 'H':
					return int(Editor_Key.Home)
				case 'F':
					return int(Editor_Key.End)
				}
			}
		} else if seq[0] == 'O' {
			switch seq[1] {
			case 'H':
				return int(Editor_Key.Home)
			case 'F':
				return int(Editor_Key.End)
			}
		}

		return ESCAPE_SEQUENCE
	}

	return char
}

editor_draw_rows :: proc(eb: ^[dynamic]u8) {
	for i in 0 ..< Config.screen_rows {
		file_row := i + Config.row_offset
		if file_row >= len(Config.rows) {
			if len(Config.rows) == 0 && i == Config.screen_rows / 3 {
				buf := make([]byte, Config.screen_rows, context.temp_allocator)
				fmt.bprintf(buf, "Teo editor -- version %v", VERSION)
				padding := (Config.screen_cols - len(buf)) / 2
				if padding > 0 {
					eb_append(eb, "~")
					padding -= 1
				}
				for padding > 0 {
					eb_append(eb, " ")
					padding -= 1
				}
				eb_append(eb, buf)
			} else {
				eb_append(eb, "~")
			}
		} else {
			if len(Config.rows[file_row].data) > Config.screen_cols {
				eb_append(eb, Config.rows[file_row].data[:Config.screen_cols])
			}
			eb_append(eb, Config.rows[file_row].data)
		}

		eb_append(eb, CLEAR_CURRENT_LINE)
		if i < Config.screen_rows - 1 {
			eb_append(eb, "\r\n")
		}
	}
}

clear_screen_and_reposition_now :: proc() {
	os.write(os.stdout, transmute([]u8)string(CLEAR_SCREEN))
	os.write(os.stdout, transmute([]u8)string(SET_CURSOR_TO_TOP))
}

editor_scroll :: proc() {
	if Config.cursor_y < Config.row_offset {
		Config.row_offset = Config.cursor_y
	}

	if Config.cursor_y >= Config.row_offset + Config.screen_rows {
		Config.row_offset = Config.cursor_y - Config.screen_rows + 1
	}
}

editor_refresh_screen :: proc() {
	editor_scroll()

	eb := make([dynamic]u8, context.temp_allocator)

	eb_append(&eb, HIDE_CURSOR)
	eb_append(&eb, SET_CURSOR_TO_TOP)

	editor_draw_rows(&eb)

	buf := make([]byte, 15, context.temp_allocator)
	eb_append(
		&eb,
		fmt.bprintf(
			buf,
			SET_CURSOR_TO_LOCATION,
			(Config.cursor_y - Config.row_offset) + 1,
			Config.cursor_x + 1,
		),
	)
	eb_append(&eb, SHOW_CURSOR)

	os.write(os.stdout, eb[:])
}

editor_open :: proc(filename: string) {
	fh, f_err := os.open(filename)
	if f_err != nil {
		sb := strings.builder_make(context.temp_allocator)
		strings.write_string(&sb, "Failed to open file: ")
		strings.write_string(&sb, filename)
		the_string := strings.to_string(sb)
		die(the_string)
	}
	defer os.close(fh)

	data, ok := os.read_entire_file(fh, allocator = context.temp_allocator)
	if !ok {
		sb := strings.builder_make(context.temp_allocator)
		strings.write_string(&sb, "Failed to read file: ")
		strings.write_string(&sb, filename)
		the_string := strings.to_string(sb)
		die(the_string)
	}

	lines := strings.split_lines(string(data), context.temp_allocator)

	for line in lines {
		to_append := transmute([]u8)line
		editor_append_row(to_append)
	}
}

editor_append_row :: proc(row: []u8) {
	new_row := Editor_Row{slice.clone(row)}
	append(&Config.rows, new_row)
}
