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
    // TODO: support webseeding extension
    // TODO: support DHT - Distributed Hash Tables
    // TODO: support multiple files
    announce: string, // URL of the tracker
    announce_list: []string,
    info_hash: [20]byte, // hash of the info dict within the torrent file
    length: int, // size of the file in bytes
    name: string, // suggested filename/folder name
    piece_length: int, // bytes per piece
    pieces: [][20]u8, // SHA-1 hashes for each piece
    url_list: []string, // list of HTTP URLs for HTTP seeds
}

TrackerState :: enum {
    Started,
    Active,
    Stopped,
    Completed,
}

Tracker :: struct {
    socket: net.TCP_Socket,
    path: string,
    info_hash: string,
    peer_id: string,
    port: string,
    uploaded: int,
    downloaded: int,
    left: int,
    state: TrackerState,
    interval: int,
    peers: []Peer,
}

Peer :: struct {
    endpoint: net.Endpoint,
    socket: net.TCP_Socket,
    am_choking: bool,
    am_interested: bool,
    peer_choking: bool,
    peer_interested: bool,
    have: BitField,
    // should I track peer download/upload rates here?
}

open :: proc(filename: string) -> Torrent {
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
        announce_list: [dynamic]string
        for announce in bcode["announce-list"].([]b.Value) {
            append(&announce_list, announce.(string))
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

parse_host_and_path :: proc(announce: string) -> (host: string, target: string) {
    strs, err := strings.split_n(announce, "/", 4)
    defer delete(strs)
    // only support HTTP currently
    assert(strings.compare(strs[0], "http:") == 0)
    if len(strs) != 4 {
        fmt.println("error parsing hostname from announce:", err, strs)
    }
    return strs[2], strs[3]
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
    p.endpoint.address = net.IP4_Address{peer[0], peer[1], peer[2], peer[3]}
    p.endpoint.port = cast(int)peer[4] * 0x100 + cast(int)peer[5]
    p.am_choking = true
    p.am_interested = false
    p.peer_choking = true
    p.peer_interested = false
    return p
}

gen_handshake :: proc(tracker: Tracker) -> []byte {
    handshake: [dynamic]byte

    pstr := "BitTorrent protocol"
    pstr_len := cast(byte)len(pstr)
    extensions: [8]byte = {0, 0, 0, 0, 0, 0, 0, 0}

    append(&handshake, pstr_len)
    append(&handshake, pstr)
    append(&handshake, transmute(string)extensions[:])
    append(&handshake, tracker.info_hash)
    append(&handshake, tracker.peer_id)

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

tracker_init :: proc(torrent: ^Torrent) -> (tracker: Tracker, err: net.Network_Error) {
    // TODO: handle HTTPS/SSL
    host, path: string
    if torrent.announce != "" {
        host, path = parse_host_and_path(torrent.announce)
    } else if torrent.announce_list != nil {
        // TODO: handle all urls in announce-list
        host, path = parse_host_and_path(torrent.announce_list[0])
    } else {
        panic("no announce urls")
    }
    tracker.path = path
    endpoint := net.resolve_ip4(host) or_return
    // do I need to keep the endpoint after connecting?
    tracker.socket = net.dial_tcp(endpoint) or_return
    tracker.info_hash = transmute(string)torrent.info_hash[:]
    tracker.peer_id = gen_peer_id(allocator = context.temp_allocator)
    tracker.port = "6881"
    tracker.uploaded = 0
    tracker.downloaded = 0
    tracker.left = torrent.length
    tracker.state = .Started

    return
}

tracker_announce :: proc(tracker: ^Tracker) {
    // how to handle change of state to stopped or completed?
    req := strings.builder_make()
    defer strings.builder_destroy(&req)
    strings.write_string(&req, "GET /")
    strings.write_string(&req, tracker.path)
    strings.write_rune(&req, '?')
    event: string
    switch tracker.state {
        case .Started:
            event = "started"
            tracker.state = .Active
        case .Active:
            event = ""
        case .Stopped:
            event = "stopped"
        case .Completed:
            event = "completed"
    }
    escaped_infohash := url_encode(tracker.info_hash)
    defer delete(escaped_infohash)
    escaped_peerid := url_encode(tracker.peer_id)
    defer delete(escaped_peerid)
    params := strings.concatenate({
        "info_hash=", escaped_infohash, "&",
        "peer_id=", escaped_peerid, "&",
        "port=", tracker.port, "&",
        "uploaded=", fmt.tprint(tracker.uploaded), "&",
        "downloaded=", fmt.tprint(tracker.downloaded), "&",
        "left=", fmt.tprint(tracker.left), "&",
        "compact=1&",
        "event=", event})
    defer delete(params)
    strings.write_string(&req, params)
    strings.write_string(&req, " HTTP/1.1\r\n")

    strings.write_string(&req, "\r\n")
    req_str := strings.to_string(req)
    req_bytes := transmute([]byte)req_str
    bytes, err := net.send_tcp(tracker.socket, req_bytes)
    if err != nil {
        fmt.println("announce error:", err, "bytes sent:", bytes)
        panic("could not announce to tracker")
    }
}

tracker_response :: proc(tracker: ^Tracker) {
    response: [1000]byte
    bytes, err := net.recv_tcp(tracker.socket, response[:])
    if bytes == 0 do return
    // for bytes == 0 {
    //     //try again? is this the right thing to do?
    //     bytes, err = net.recv_tcp(tracker.socket, response[:])
    // }
    if err != nil {
        fmt.println("Response err: ", err)
        panic("error receiving response from tracker")
    }
    strs, _ := strings.split(transmute(string)response[:bytes], "\r\n\r\n")
    defer delete(strs)
    if len(strs) < 2 {
        fmt.println(strs)
        panic("unexpected response format")
    }
    data := transmute([]byte)strs[1]
    r := b.decode(data, context.temp_allocator).(map[string]b.Value)
    tracker.interval = r["interval"].(int)
    tracker.peers = parse_peers(r["peers"].(string))

    // print out for debugging
    fmt.println("Interval: ", tracker.interval, " seconds")
    for peer in tracker.peers {
        fmt.println(peer.endpoint.address, ":", peer.endpoint.port, sep="")
    }
}

tracker_destroy :: proc(tracker: Tracker) {
    delete(tracker.peers)
    net.close(tracker.socket)
}

torrent_destroy :: proc(torrent: Torrent) {
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

    // load torrent file
    torrent_file := os.args[1]
    torrent := open(torrent_file)
    defer torrent_destroy(torrent)
    if torrent.announce == "" do return // only support single announce

    tracker, err := tracker_init(&torrent)
    defer tracker_destroy(tracker)
    if err != nil {
        fmt.println("Tracker error:", err)
        panic("Could not connect to tracker")
    }

    // initial announce
    tracker_announce(&tracker)

    // and response
    tracker_response(&tracker)

    // handshake to send peers upon connecting
    handshake := gen_handshake(tracker)
    defer delete(handshake)

    // when stopping, inform the tracker
    tracker.state = .Stopped
    tracker_announce(&tracker)

    free_all(context.temp_allocator)
}
