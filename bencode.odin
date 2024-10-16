package bencode

import "core:bytes"
import "core:fmt"
import "core:os"
import "core:strconv"

// probably don't need a main, but it's here for testing
main :: proc() {
    if len(os.args) == 1 {
        fmt.println("Please specify a file to parse")
        return
    } else if len(os.args) > 2 {
        fmt.println("Too many arguments")
        return
    }
    filename := os.args[1]
    data, ok := os.read_entire_file(filename)
    if !ok {
        fmt.println("error reading file")
        return
    }
    r := bytes.Reader{s = data, i = 0, prev_rune = -1}
    result := decode1(&r)
    fmt.println(result)
}

Value :: union {
	string,
	int,
	[]Value,
	map[string]Value,
}

decode1 :: proc(input: ^bytes.Reader) -> Value {
	val: Value
    next := input.s[input.i]
	switch next {
        case 'd':
            val = decode_dict(input)
        case 'l':
            val = decode_list(input)
        case '0' ..= '9':
            val = decode_string(input)
        case 'i':
            val = decode_int(input)
        case:
            fmt.println("invalid bencode: ", next)
            return nil
	}

	return val
}

decode_dict :: proc(input: ^bytes.Reader) -> map[string]Value {
	dict := make(map[string]Value)

    d, err := bytes.reader_read_byte(input)
    if err != .None || d != 'd' {
        fmt.println("dict decode error: ", err, ", d = ", d)
        delete(dict)
        return nil
    }

    key: string
    val: Value

    for input.s[input.i] != 'e' {
        key = decode_string(input)
        val = decode1(input)
        dict[key] = val
    }

    e: u8
    e, err = bytes.reader_read_byte(input)
    if err != .None || e != 'e' {
        fmt.println("dict decode error: ", err, ", e = ", e)
        delete(dict)
        return nil
    }

	return dict
}

decode_list :: proc(input: ^bytes.Reader) -> []Value {
	list := make([dynamic]Value)

    l, err := bytes.reader_read_byte(input)
    if err != .None || l != 'l' {
        fmt.println("dict decode error: ", err, ", l = ", l)
        delete(list)
        return nil
    }

    val: Value
    for input.s[input.i] != 'e' {
        val = decode1(input)
        append(&list, val)
    }

    e: u8
    e, err = bytes.reader_read_byte(input)
    if err != .None || e != 'e' {
        fmt.println("dict decode error: ", err, ", e = ", e)
        delete(list)
        return nil
    }

	return list[:]
}

decode_string :: proc(input: ^bytes.Reader) -> string {
    length_str: [dynamic]u8

    next, err := bytes.reader_read_byte(input)
    if err != .None {
        fmt.println("string length read error: ", err)
        return ""
    }
    for next != ':' {
        append(&length_str, next)
        next, err = bytes.reader_read_byte(input)
        if err != .None {
            fmt.println("string length read error: ", err)
            return ""
        }
    }
    length := strconv.atoi(transmute(string)length_str[:])
    str := make([]u8, length)

    n: int
    n, err = bytes.reader_read(input, str)
    if n != length || err != .None {
        fmt.println("string read error: ", err, ", n: ", n, ", length: ", length)
        return ""
    }

    return transmute(string)str
}

decode_int :: proc(input: ^bytes.Reader) -> int {

    i, err := bytes.reader_read_byte(input)
    if err != .None || i != 'i' {
        fmt.println("dict decode error: ", err, ", i = ", i)
        return -1
    }

	digits := make([dynamic]u8)
    defer delete(digits)
    for input.s[input.i] != 'e' {
        digit, err := bytes.reader_read_byte(input)
        append(&digits, digit)
    }
    n := strconv.atoi(transmute(string)digits[:])

    e: u8
    e, err = bytes.reader_read_byte(input)
    if err != .None || e != 'e' {
        fmt.println("dict decode error: ", err, ", e = ", e)
        return -1
    }

    return n
}
