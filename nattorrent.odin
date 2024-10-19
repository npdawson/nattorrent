package nattorrent

import "core:bytes"
import "core:crypto/hash"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:math/rand"
import "core:slice"
import "core:strings"
import "core:strconv"

import b "../bencode"

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
    reader := bytes.Reader{s = data, i = 0, prev_rune = -1}
    bcode := b.decode1(&reader).(map[string]b.Value)
    defer delete(bcode)

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
    binfo := b.encode1(info)
    defer delete(binfo)

    infohash: [20]byte
    hash.hash(.Insecure_SHA1, binfo, infohash[:])

    return infohash
}

url_encode :: proc(str: string) -> string {
    b := strings.builder_make()
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
    defer delete(params)
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
    return strs[2], strs[3]
}

parse_response :: proc(res: []byte) -> TrackerResponse {
    strs, err := strings.split(transmute(string)res, "\r\n\r\n")
    defer delete(strs)
    if len(strs) < 2 {
        return {}
    }
    data := transmute([]byte)strs[1]
    reader := bytes.Reader{s = data, i = 0, prev_rune = -1}
    r := b.decode1(&reader).(map[string]b.Value)
    defer delete(r)
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

free_torrent :: proc(torrent: Torrent) {
    delete(torrent.name)
    delete(torrent.pieces)
    delete(torrent.announce)
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

    torrent_file := os.args[1]
    torrent := open(torrent_file)
    defer free_torrent(torrent)
    if torrent.announce == "" do return
    ih_str := transmute(string)torrent.info_hash[:]
    infohash := url_encode(ih_str)
    defer delete(infohash)
    //fmt.println(infohash)
    peer_id := gen_peer_id()
    defer delete(peer_id)
    //fmt.println(peer_id)
    tracker_req := TrackerRequest{info_hash = infohash, peer_id = url_encode(peer_id),
                                  port = "6881", uploaded = 0, downloaded = 0,
                                  left = torrent.length, compact = true, event = .Started}
    defer delete(tracker_req.peer_id)
    url := tracker_url(torrent, tracker_req)
    defer delete(url)
    //fmt.println(url)

    //// connect to tracker
    //host, target := parse_hostname_and_port(torrent.announce)
    //ep4, err := net.resolve_ip4(host)
    //socket, err2 := net.dial_tcp(ep4)
    //defer net.close(socket)
    //
    //// build request message
    //req_str := get_string(url)
    ////fmt.println(req_str)
    //req := transmute([]u8)req_str
    //
    //// send GET request
    //bytes, err3 := net.send(socket, req)
    //
    //// get response
    //response: [1000]byte
    //bytes, err3 = net.recv(socket, response[:])
    //if bytes == 0 {
    //    fmt.println("Response err: ", err3)
    //} else {
    //    fmt.println(transmute(string)response[:bytes])
    //
    //    // parse and print response
    //    r := parse_response(response[:bytes])
    //    fmt.println("Interval: ", r.interval, " seconds")
    //    for peer in r.peers {
    //        fmt.println(peer.ip, ":", peer.port, sep="")
    //    }
    //}
    //
    //// when stopping, inform the tracker
    //tracker_req.event = .Stopped
    //url = tracker_url(torrent, tracker_req)
    //req_str = get_string(url)
    //req = transmute([]u8)req_str
    //bytes, err3 = net.send(socket, req)

    free_all(context.temp_allocator)
}
