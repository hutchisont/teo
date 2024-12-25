package teo

import "core:fmt"
import "core:io"
import "core:os"

main :: proc() {
	buf := make([dynamic]byte)
	defer delete(buf)

	input_stream := os.stream_from_handle(os.stdin)

	for {
		char, size, err := io.read_rune(input_stream)
		switch {
		case err != nil:
			fmt.eprintfln("\nError: %v", err)
			os.exit(1)
		case char == 'q':
			os.exit(0)
		}
	}
}
