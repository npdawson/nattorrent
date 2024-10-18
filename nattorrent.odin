package nattorrent

import "core:bytes"
import "core:crypto/hash"
import "core:fmt"
import "core:os"
import "core:math/rand"
import "core:slice"
import "core:strings"
import "core:strconv"

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

TrackerRequest :: struct {
    info_hash: string, // url encoded
    peer_id: string,   // url encoded
    port: string,
    uploaded: int,
    downloaded: int,
    compact: bool,
    left: int,
    event: Maybe(Event),
}

Event :: enum{Started, Stopped, Completed}

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

url_encode :: proc(str: string) -> string {
    b := strings.builder_make(len(str)+16)
    for i in 0..<len(str) {
        switch str[i] {
            case '0'..='9', 'a'..='z', 'A'..='Z', '.', '-', '_', '~':
                strings.write_byte(&b, str[i])
            case:
                buf: [2]u8
                t := strconv.append_int(buf[:], i64(str[i]), 16)
                strings.write_byte(&b, '%')
                strings.write_string(&b, t)
        }
    }
    return strings.to_string(b)
}

gen_peer_id :: proc() -> string {
    b := strings.builder_make()

    // 2 letters for client name, 4 digits for version
    client_id := "-NT0000-"
    strings.write_string(&b, client_id)

    // generate random bytes for the remainder
    num_rand_bytes := 20 - len(client_id)
    for i := 0; i < num_rand_bytes; i += 1 {
        strings.write_byte(&b, u8(rand.float64()*256))
    }

    return strings.to_string(b)
}

tracker_url :: proc(torrent: Torrent, request: TrackerRequest) -> string {
    b := strings.builder_make()

    strings.write_string(&b, torrent.announce)
    strings.write_rune(&b, '?')
    event: string
    switch request.event {
        case .Started:
            event = "started"
        case .Stopped:
            event = "stopped"
        case .Completed:
            event = "completed"
        case:
            event = ""
    }
    params := strings.concatenate({
        "info_hash=", request.info_hash, "&",
        "peer_id=", request.peer_id, "&",
        "port=", request.port, "&",
        "uploaded=", fmt.tprint(request.uploaded), "&",
        "downloaded=", fmt.tprint(request.downloaded), "&",
        "left=", fmt.tprint(request.left), "&",
        "compact=", "1" if request.compact else "0", "&",
        "event=", event})
    strings.write_string(&b, params)
    return strings.to_string(b)
}

main :: proc() {
    torrent_file := os.args[1]
    torrent := open(torrent_file)
    ih_str := transmute(string)torrent.info_hash[:]
    infohash := url_encode(ih_str)
    fmt.println(infohash)
    peer_id := gen_peer_id()
    fmt.println(peer_id)
    fmt.println(url_encode(peer_id))
    tracker_req := TrackerRequest{info_hash = infohash, peer_id = url_encode(peer_id),
                                  port = "6881", uploaded = 0, downloaded = 0,
                                  left = torrent.length, compact = true, event = .Started}
    url := tracker_url(torrent, tracker_req)
    fmt.println(url)
}
