package nattorrent

import "core:encoding/endian"

messageID :: distinct u8

MsgChoke: messageID : 0
MsgUnchoke: messageID : 1
MsgInterested: messageID : 2
MsgNotInterested: messageID : 3
MsgHave: messageID : 4
MsgBitfield: messageID : 5
MsgRequest: messageID : 6
MsgPiece: messageID : 7
MsgCancel: messageID : 8
MsgPort: messageID : 9

Message :: struct {
	ID:		 messageID,
	payload: []byte,
}

gen_msg :: proc(id: messageID, payload: []byte) -> []byte {
	msg: [dynamic]byte

	length: u32 = cast(u32)len(payload) + 1
	len_bytes: [4]byte
	_ = endian.put_u32(len_bytes[:], .Big, length)
	append_elems(&msg, ..len_bytes[:])

	append(&msg, cast(byte)id)

	append_elems(&msg, ..payload)

	return msg[:]
}

parse_msg :: proc(data: []byte) -> (msg: Message, err: string) {
	length, ok := endian.get_u32(data[:4], .Big)
	if length == 0 {
		// how to handle keepalive message type?
		return
	}
	if !ok {
		err = "couldn't read msg length"
		return
	}
	remainder := data[4:]
	msg.ID = cast(messageID)remainder[0]
	if length > 1 {
		msg.payload = remainder[1:length]
	}
	return
}
