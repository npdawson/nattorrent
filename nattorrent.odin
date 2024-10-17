package nattorrent

import "core:bytes"
import "core:fmt"
import "core:os"

import "bencode"

// TODO: implement BitTorrent v2
Torrent :: struct {
    // TODO: support HTTP seeds extension
    // TODO: support multiple trackers
    // TODO: support DHT - Distributed Hash Tables
    announce: string, // URL of the tracker
    url_list: []string, // list of HTTP URLs for HTTP seeds
    info: TorrentInfo, // info about the file(s)
}

TorrentInfo :: struct {
    // TODO: support multiple files
    length: int, // size of the file in bytes
    name: string, // suggested filename/folder name
    piece_length: int, // bytes per piece
    pieces: [][20]u8, // SHA-1 hashes for each piece
}

open :: proc(filename: string) -> Torrent {
    data, ok := os.read_entire_file(filename)
    if !ok {
        fmt.println("read file failed")
        return {}
    }
    reader := bytes.Reader{s = data, i = 0, prev_rune = -1}
    bcode := bencode.decode1(&reader).(map[string]bencode.Value)

    torrent := Torrent{}
    torrent.announce = bcode["annouce"].(string)
    url_list: [dynamic]string
    for url in bcode["url-list"].([]bencode.Value) {
        append(&url_list, url.(string))
    }
    torrent.url_list = url_list[:]
    torrent.info.name = bcode["info"].(map[string]bencode.Value)["name"].(string)
    torrent.info.length = bcode["info"].(map[string]bencode.Value)["length"].(int)
    torrent.info.piece_length = bcode["info"].(map[string]bencode.Value)["piece length"].(int)
    pieces: [dynamic][20]u8
    pieces_str := transmute([]u8)bcode["info"].(map[string]bencode.Value)["pieces"].(string)
    for i := 0; i < len(pieces_str); i += 20 {
        hash: [20]u8
        copy(hash[:], pieces_str[i:])
        append(&pieces, hash)
    }
    torrent.info.pieces = pieces[:]

    return torrent
}

main :: proc() {
}
