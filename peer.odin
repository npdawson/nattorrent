package nattorrent

import "core:crypto/hash"
import "core:fmt"
import "core:net"
import "core:math/rand"
import "core:strings"

import b "../bencode"

BitField :: distinct []byte

Peer :: struct {
	endpoint:		 net.Endpoint,
	socket:			 net.TCP_Socket,
	am_choking:		 bool,
	am_interested:	 bool,
	peer_choking:	 bool,
	peer_interested: bool,
	have:			 BitField,
	// should I track peer download/upload rates here?
}

info_hash :: proc(info: map[string]b.Value) -> [20]byte {
	binfo := b.encode1(info, context.temp_allocator)

	infohash: [20]byte
	hash.hash(.Insecure_SHA1, binfo, infohash[:])

	return infohash
}

gen_peer_id :: proc(allocator := context.allocator) -> string {
	b := strings.builder_make(allocator = allocator)

	// 2 letters for client name, 4 digits for version
	client_id := "-NT0000-"
	strings.write_string(&b, client_id)

	// generate random bytes for the remainder
	num_rand_bytes := 20 - len(client_id)
	for i := 0; i < num_rand_bytes; i += 1 {
		strings.write_byte(&b, u8(rand.float64() * 256))
	}

	return strings.to_string(b)
}

parse_peers :: proc(peers_str: string) -> []Peer {
	peers: [dynamic]Peer

	if len(peers_str) % 6 != 0 {
		fmt.println("peers format error")
		return {}
	}
	peers_bytes := transmute([]byte)peers_str
	for i := 0; i < len(peers_bytes); i += 6 {
		p := parse_peer(peers_bytes[i:i + 6])
		append(&peers, p)
	}

	if len(peers) != len(peers_bytes) / 6 {
		fmt.println(
			"error parsing peers: number parsed:",
			len(peers),
			"Number sent:",
			len(peers_bytes) / 6,
		)
	}

	return peers[:]
}

parse_peer :: proc(peer: []byte) -> Peer {
	p: Peer
	if len(peer) != 6 {
		fmt.println("peer needs to be a 6 byte slice. length: ", len(peer))
		return p
	}
	p.endpoint.address = net.IP4_Address{peer[0], peer[1], peer[2], peer[3]}
	p.endpoint.port = cast(int)peer[4] * 0x100 + cast(int)peer[5]
	p.am_choking = true
	p.am_interested = false
	p.peer_choking = true
	p.peer_interested = false
	return p
}

parse_handshake :: proc(hs: []byte) -> (infohash: string, peerid: string, err: string) {
	pstr_len := hs[0]
	pstr_end := pstr_len + 1
	pstr := transmute(string)hs[1:pstr_end]
	if strings.compare(pstr, "BitTorrent protocol") != 0 {
		err = fmt.tprintf("Incorrect protocol:", pstr)
		return
	}
	ext_end := pstr_end + 8
	extensions := hs[pstr_end:ext_end]
	ih_end := ext_end + 20
	infohash = transmute(string)hs[ext_end:ih_end]
	peerid = transmute(string)hs[ih_end:ih_end + 20]
	return
}

has_piece :: proc(bf: BitField, index: uint) -> bool {
	byte_index := index / 8
	offset := index % 8
	return bf[byte_index] >> (7 - offset) & 1 != 0
}

set_piece :: proc(bf: ^BitField, index: uint) {
	byte_index := index / 8
	offset := index % 8
	bf[byte_index] |= (1 << (7 - offset))
}

