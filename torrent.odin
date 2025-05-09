package nattorrent

import "core:fmt"
import "core:os"

import b "../bencode"

// TODO: implement BitTorrent v2
Torrent :: struct {
	// TODO: support webseeding extension
	// TODO: support DHT - Distributed Hash Tables
	// TODO: support multiple files
	announce:      string, // URL of the tracker
	announce_list: [][]string,
	info_hash:     [20]byte, // hash of the info dict within the torrent file
	length:        int, // size of the file in bytes
	left:		   int, // bytes left until 100% of files are downloaded
	name:          string, // suggested filename/folder name
	piece_length:  int, // bytes per piece
	pieces:        [][20]u8, // SHA-1 hashes for each piece
	url_list:      []string, // list of HTTP URLs for HTTP seeds
	peer_id:	   string,
	peers:		   []Peer,
}

open_file :: proc(filename: string) -> Torrent {
	data, ok := os.read_entire_file(filename)
	defer delete(data)
	if !ok {
		fmt.println("read file failed")
		return {}
	}
	bcode := b.decode(data, context.temp_allocator).(map[string]b.Value)

	torrent := Torrent{}
	if bcode["announce"] != nil {
		torrent.announce = bcode["announce"].(string)
	}
	if bcode["announce-list"] != nil {
		announce_list: [dynamic][]string
		for tier in bcode["announce-list"].([]b.Value) {
			tier_list: [dynamic]string
			for announce in tier.([]b.Value) {
				append(&tier_list, announce.(string))
			}
			append(&announce_list, tier_list[:])
		}
		torrent.announce_list = announce_list[:]
	}
	if bcode["url-list"] != nil {
		url_list: [dynamic]string
		for url in bcode["url-list"].([]b.Value) {
			append(&url_list, url.(string))
		}
		torrent.url_list = url_list[:]
	}
	info_map := bcode["info"].(map[string]b.Value)
	torrent.info_hash = info_hash(info_map)
	torrent.name = info_map["name"].(string)
	torrent.length = info_map["length"].(int)
	torrent.left = torrent.length
	torrent.piece_length = info_map["piece length"].(int)
	pieces: [dynamic][20]u8
	pieces_str := transmute([]u8)info_map["pieces"].(string)
	for i := 0; i < len(pieces_str); i += 20 {
		hash: [20]u8
		copy(hash[:], pieces_str[i:])
		append(&pieces, hash)
	}
	torrent.pieces = pieces[:]
	torrent.peer_id = gen_peer_id(allocator = context.temp_allocator)

	return torrent
}

torrent_destroy :: proc(torrent: Torrent) {
	delete(torrent.pieces)
	delete(torrent.url_list)
}
