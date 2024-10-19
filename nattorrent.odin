package nattorrent

import "core:crypto/hash"
import "core:encoding/endian"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:math/rand"
import "core:slice"
import "core:strings"
import "core:strconv"

import b "../bencode"

messageID :: distinct u8

MsgChoke:         messageID : 0
MsgUnchoke:       messageID : 1
MsgInterested:    messageID : 2
MsgNotInterested: messageID : 3
MsgHave:          messageID : 4
MsgBitfield:      messageID : 5
MsgRequest:       messageID : 6
MsgPiece:         messageID : 7
MsgCancel:        messageID : 8
MsgPort:          messageID : 9

Message :: struct {
    ID: messageID,
    payload: []byte,
}

BitField :: distinct []byte

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
    info_hash: string,
    peer_id: string,
    port: string,
    uploaded: int,
    downloaded: int,
    compact: bool,
    left: int,
    event: Maybe(Event),
}

TrackerResponse :: struct {
    failure_reason: string,
    warning: string,
    interval: int,
    min_interval: int,
    tracker_id: string,
    complete: int, // number of seeders
    incomplete: int, // number of leechers
    peers: []Peer,
}

Peer :: struct {
    ip: string,
    port: string,
    am_choking: bool,
    am_interested: bool,
    peer_choking: bool,
    peer_interested: bool,
}

Event :: enum{Started, Stopped, Completed}

open :: proc(filename: string) -> Torrent {
    data, ok := os.read_entire_file(filename)
    defer delete(data)
    if !ok {
        fmt.println("read file failed")
        return {}
    }
    bcode := b.decode(data, context.temp_allocator).(map[string]b.Value)

    torrent := Torrent{}
    assert(bcode["announce"] != nil)
    torrent.announce = bcode["announce"].(string)
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
    binfo := b.encode1(info, context.temp_allocator)

    infohash: [20]byte
    hash.hash(.Insecure_SHA1, binfo, infohash[:])

    return infohash
}

url_encode :: proc(str: string, allocator := context.allocator) -> string {
    b := strings.builder_make(allocator = allocator)
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

gen_peer_id :: proc(allocator := context.allocator) -> string {
    b := strings.builder_make(allocator = allocator)

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

tracker_url :: proc(torrent: Torrent, request: TrackerRequest, allocator := context.allocator) -> string {
    b := strings.builder_make(allocator = allocator)

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
        "info_hash=", url_encode(request.info_hash, allocator = allocator), "&",
        "peer_id=", url_encode(request.peer_id, allocator = allocator), "&",
        "port=", request.port, "&",
        "uploaded=", fmt.tprint(request.uploaded), "&",
        "downloaded=", fmt.tprint(request.downloaded), "&",
        "left=", fmt.tprint(request.left), "&",
        "compact=", "1" if request.compact else "0", "&",
        "event=", event}, allocator = context.temp_allocator)
    strings.write_string(&b, params)
    return strings.to_string(b)
}

get_string :: proc(url: string) -> string {
    host, target := parse_hostname_and_port(url)
    return strings.concatenate({"GET /", target, " HTTP/1.1\r\n",
                                "Host: ", host, "\r\n",
                                "\r\n"})
}

parse_hostname_and_port :: proc(announce: string) -> (host: string, target: string) {
    strs, err := strings.split_n(announce, "/", 4)
    defer delete(strs)
    if len(strs) != 4 {
        fmt.println("error parsing hostname from announce:", err, strs)
    }
    return strs[2], strs[3]
}

parse_response :: proc(res: []byte) -> TrackerResponse {
    strs, err := strings.split(transmute(string)res, "\r\n\r\n")
    defer delete(strs)
    if len(strs) < 2 {
        return {}
    }
    data := transmute([]byte)strs[1]
    r := b.decode(data, context.temp_allocator).(map[string]b.Value)
    tr: TrackerResponse
    tr.interval = r["interval"].(int)
    tr.peers = parse_peers(r["peers"].(string))
    return tr
}

parse_peers :: proc(peers_str: string) -> []Peer {
    peers: [dynamic]Peer

    if len(peers_str) % 6 != 0 {
        fmt.println("peers format error")
        return {}
    }
    peers_bytes := transmute([]byte)peers_str
    for i := 0; i < len(peers_bytes); i += 6 {
        p := parse_peer(peers_bytes[i:i+6])
        append(&peers, p)
    }

    if len(peers) != len(peers_bytes) / 6 {
        fmt.println("error parsing peers: number parsed:", len(peers), "Number sent:", len(peers_bytes) / 6)
    }

    return peers[:]
}

parse_peer :: proc(peer: []byte) -> Peer {
    p: Peer
    if len(peer) != 6 {
        fmt.println("peer needs to be a 6 byte slice. length: ", len(peer))
        return p
    }
    p.ip = fmt.tprintf("%d.%d.%d.%d", peer[0], peer[1], peer[2], peer[3])
    p.port = fmt.tprintf("%d", cast(u16)peer[4] * 0x100 + cast(u16)peer[5])
    p.am_choking = true
    p.am_interested = false
    p.peer_choking = true
    p.peer_interested = false
    return p
}

gen_handshake :: proc(tracker_req: TrackerRequest) -> []byte {
    handshake: [dynamic]byte

    pstr := "BitTorrent protocol"
    pstr_len := cast(byte)len(pstr)
    extensions: [8]byte = {0, 0, 0, 0, 0, 0, 0, 0}

    append(&handshake, pstr_len)
    append(&handshake, pstr)
    append(&handshake, transmute(string)extensions[:])
    append(&handshake, tracker_req.info_hash)
    append(&handshake, tracker_req.peer_id)

    return handshake[:]
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
    peerid = transmute(string)hs[ih_end:ih_end+20]
    return
}

gen_msg :: proc(id: messageID, payload: []byte) -> []byte {
    msg: [dynamic]byte

    length: u32 = cast(u32)len(payload) + 1
    len_bytes: [4]byte
    ok := endian.put_u32(len_bytes[:], .Big, length)
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

has_piece :: proc(bf: BitField, index: uint) -> bool {
    byte_index := index / 8
    offset := index % 8
    return bf[byte_index]>>(7-offset)&1 != 0
}

set_piece :: proc(bf: ^BitField, index: uint) {
    byte_index := index / 8
    offset := index % 8
    bf[byte_index] |= (1 << (7 - offset))
}

free_torrent :: proc(torrent: Torrent) {
    delete(torrent.pieces)
    delete(torrent.url_list)
}

main :: proc() {
    when ODIN_DEBUG {
        // use tracking allocator when -debug to track for memory leaks
        track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)

		defer {
			if len(track.allocation_map) > 0 {
				fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
				for _, entry in track.allocation_map {
					fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
				}
			}
			if len(track.bad_free_array) > 0 {
				fmt.eprintf("=== %v incorrect frees: ===\n", len(track.bad_free_array))
				for entry in track.bad_free_array {
					fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
				}
			}
			mem.tracking_allocator_destroy(&track)
		}
    }

    quit := false

    torrent_file := os.args[1]
    torrent := open(torrent_file)
    defer free_torrent(torrent)
    if torrent.announce == "" do return
    ih_str := transmute(string)torrent.info_hash[:]
    peer_id := gen_peer_id(allocator = context.temp_allocator)
    tracker_req := TrackerRequest{info_hash = ih_str, peer_id = peer_id,
                                  port = "6881", uploaded = 0, downloaded = 0,
                                  left = torrent.length, compact = true, event = .Started}
    url := tracker_url(torrent, tracker_req)
    defer delete(url)

    // handshake to send peers upon connecting
    handshake := gen_handshake(tracker_req)
    defer delete(handshake)

    // // connect to tracker
    // host, target := parse_hostname_and_port(torrent.announce)
    // ep4, err := net.resolve_ip4(host)
    // socket, err2 := net.dial_tcp(ep4)
    // defer net.close(socket)
    //
    // // build request message
    // req_str := get_string(url)
    // defer delete(req_str)
    // //fmt.println(req_str)
    // req := transmute([]u8)req_str
    //
    // // send GET request
    // bytes, err3 := net.send_tcp(socket, req)
    //
    // // get response
    // response: [1000]byte
    // bytes, err3 = net.recv_tcp(socket, response[:])
    // if bytes == 0 || err3 != nil {
    //     fmt.println("Response err: ", err3)
    //     quit = true
    // } else {
    //     // fmt.println(transmute(string)response[:bytes])
    //
    //     // parse and print interval and peer list
    //     r := parse_response(response[:bytes])
    //     defer delete(r.peers)
    //     fmt.println("Interval: ", r.interval, " seconds")
    //     for peer in r.peers {
    //         fmt.println(peer.ip, ":", peer.port, sep="")
    //     }
    // }
    //
    // // event loop
    // for !quit {
    //
    // }

    // when stopping, inform the tracker
    // tracker_req.event = .Stopped
    // url = tracker_url(torrent, tracker_req, allocator = context.temp_allocator)
    // delete(req_str)
    // req_str = get_string(url)
    // req = transmute([]u8)req_str
    // bytes, err3 = net.send(socket, req)

    free_all(context.temp_allocator)
}
