package nattorrent

import "core:fmt"
import "core:net"
import "core:strings"
import "core:strconv"

import b "../bencode"

TrackerState :: enum {
	Started,
	Active,
	Stopped,
	Completed,
}

Tracker :: struct {
	socket:		net.TCP_Socket,
	path:		string,
	info_hash:	string,
	peer_id:	string,
	port:		string,
	uploaded:	int,
	downloaded: int,
	left:		int,
	state:		TrackerState,
	interval:	int,
	peers:		[]Peer,
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

url_encode :: proc(str: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator = allocator)
	for i in 0 ..< len(str) {
		switch str[i] {
		case '0' ..= '9', 'a' ..= 'z', 'A' ..= 'Z', '.', '-', '_', '~':
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

tracker_init :: proc(torrent: ^Torrent) -> (tracker: Tracker, err: net.Network_Error) {
	tracker_url: string
	if torrent.announce_list != nil {
		// TODO: handle all urls in announce-list
		tracker_url = torrent.announce_list[0][0]
	} else if torrent.announce != "" {
		tracker_url = torrent.announce
	} else {
		panic("no announce urls")
	}
	// TODO: handle HTTPS/SSL
	protocol, host, path, _, _ := net.split_url(tracker_url)
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
	params := strings.concatenate(
		{
			"info_hash=",
			escaped_infohash,
			"&",
			"peer_id=",
			escaped_peerid,
			"&",
			"port=",
			tracker.port,
			"&",
			"uploaded=",
			fmt.tprint(tracker.uploaded),
			"&",
			"downloaded=",
			fmt.tprint(tracker.downloaded),
			"&",
			"left=",
			fmt.tprint(tracker.left),
			"&",
			"compact=1&",
			"event=",
			event,
		},
	)
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
	//	   //try again? is this the right thing to do?
	//	   bytes, err = net.recv_tcp(tracker.socket, response[:])
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
		fmt.println(peer.endpoint.address, ":", peer.endpoint.port, sep = "")
	}
}

tracker_destroy :: proc(tracker: Tracker) {
	delete(tracker.peers)
	net.close(tracker.socket)
}
