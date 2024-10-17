package nattorrent

import "core:bytes"
import "core:crypto/hash"
import "core:fmt"
import "core:os"
import "core:slice"

import b "bencode"

// TODO: implement BitTorrent v2
Torrent :: struct {
    // TODO: support HTTP seeds extension
    // TODO: support multiple trackers
    // TODO: support DHT - Distributed Hash Tables
    // TODO: support multiple files
    announce: string, // URL of the tracker
    info_hash: [20]byte, // hash of the info dict within the torrent file
    length: int, // size of the file in bytes
    name: string, // suggested filename/folder name
    piece_length: int, // bytes per piece
    pieces: [][20]u8, // SHA-1 hashes for each piece
    url_list: []string, // list of HTTP URLs for HTTP seeds
}

open :: proc(filename: string) -> Torrent {
    data, ok := os.read_entire_file(filename)
    if !ok {
        fmt.println("read file failed")
        return {}
    }
    reader := bytes.Reader{s = data, i = 0, prev_rune = -1}
    bcode := b.decode1(&reader).(map[string]b.Value)

    torrent := Torrent{}
    torrent.announce = bcode["announce"].(string)
    url_list: [dynamic]string
    for url in bcode["url-list"].([]b.Value) {
        append(&url_list, url.(string))
    }
    torrent.url_list = url_list[:]
    info_map := bcode["info"].(map[string]b.Value)
    torrent.info_hash = info_hash(info_map)
    torrent.name = info_map["name"].(string)
    torrent.length = info_map["length"].(int)
    torrent.piece_length = info_map["piece length"].(int)
    pieces: [dynamic][20]u8
    pieces_str := transmute([]u8)info_map["pieces"].(string)
    for i := 0; i < len(pieces_str); i += 20 {
        hash: [20]u8
        copy(hash[:], pieces_str[i:])
        append(&pieces, hash)
    }
    torrent.pieces = pieces[:]

    return torrent
}

info_hash :: proc(info: map[string]b.Value) -> [20]byte {
    binfo := b.encode1(info)

    infohash: [20]byte
    hash.hash(.Insecure_SHA1, binfo, infohash[:])

    return infohash
}

main :: proc() {
    torrent_file := os.args[1]
    torrent := open(torrent_file)
    for b in torrent.info_hash {
        fmt.printf("%2x", b)
    }
    fmt.println()
}
