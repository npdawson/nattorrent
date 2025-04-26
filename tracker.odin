package nattorrent

import "core:fmt"
import "core:net"
import "core:strings"
import "core:strconv"

import b "../bencode"

Event :: enum {
	Started,
	Active,
	Stopped,
	Completed,
}

Tracker :: struct {
	endpoint:	net.Endpoint,
	protocol:	string,
	host:		string,
	path:		string,
	uploaded:	int,
	downloaded: int,
	state:		Event,
	interval:	int,
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
	protocol, host, path, _, _ := net.split_url(tracker_url)
	// TODO: handle HTTPS/SSL
	if protocol != "http" {
		fmt.eprintln("unsupported protocol: ", protocol)
		panic("could not initialize tracker")
	}
	tracker.endpoint = net.resolve_ip4(host) or_return
	tracker.protocol = protocol
	tracker.host, _, _ = net.split_port(host)
	tracker.path = path
	tracker.uploaded = 0
	tracker.downloaded = 0
	tracker.state = .Started

	return
}

tracker_announce :: proc(tracker: ^Tracker, torrent: ^Torrent, port: int) -> (err: net.Network_Error) {
	socket: net.TCP_Socket
	socket, err = net.dial_tcp_from_endpoint(tracker.endpoint)
	if err != nil {
		fmt.eprintln("couldn't connect to tracker")
		return
	}
	// how to handle change of state to stopped or completed?
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

	info_hash := transmute(string)torrent.info_hash[:]
	escaped_infohash := url_encode(info_hash, context.temp_allocator)
	escaped_peerid := url_encode(torrent.peer_id, context.temp_allocator)
	request_string := strings.concatenate(
		{
			"GET /",
			tracker.path,
			"?info_hash=",
			escaped_infohash,
			"&peer_id=",
			escaped_peerid,
			"&port=",
			fmt.tprint(port),
			"&uploaded=",
			fmt.tprint(tracker.uploaded),
			"&downloaded=",
			fmt.tprint(tracker.downloaded),
			"&left=",
			fmt.tprint(torrent.left),
			"&compact=1",
			"&event=",
			event,
			" HTTP/1.1\r\n",
			"Host:",
			tracker.host,
			"\r\n\r\n",
		},
		context.temp_allocator
	)

	request_bytes := transmute([]byte)request_string
	bytes: int
	bytes, err = net.send_tcp(socket, request_bytes)
	if err != nil {
		fmt.eprintln("Error announcing to tracker:", tracker.host, " | bytes sent:", bytes)
		return
	}

	response := make_slice([]byte, 2000, context.temp_allocator)
	bytes, err = net.recv_tcp(socket, response[:])
	if err != nil {
		fmt.eprintln("Error receiving response from tracker:", tracker.host)
		return
	}
	if bytes == 0 do return
	strs, _ := strings.split(transmute(string)response[:bytes], "\r\n")
	defer delete(strs)
	length := len(strs)
	// check for HTTP response
	statusline := strings.split(strs[0], " ")
	defer delete(statusline)
	if statusline[0] != "HTTP/1.1" {
		fmt.eprintln("response: ", strs[0])
		panic("not a valid HTTP 1.1 response")
	}
	// check status code
	if statusline[1] != "200" {
		fmt.eprintln("status:", statusline[1], statusline[2])
		panic("response code not OK")
	}

	if length < 2 { // TODO: better response handling
		fmt.println(strs)
		panic("unexpected response format")
	}
	data := transmute([]byte)strs[length-1]
	r := b.decode(data, context.temp_allocator).(map[string]b.Value)
	tracker.interval = r["interval"].(int)
	// TODO: add peers to list rather than replace
	torrent.peers = parse_peers(r["peers"].(string))

	// print out for debugging
	fmt.println("Interval: ", tracker.interval, " seconds")
	for peer in torrent.peers {
		fmt.println(peer.endpoint.address, ":", peer.endpoint.port, sep = "")
	}

	net.close(socket)
	free_all(context.temp_allocator)
	return nil
}

tracker_destroy :: proc(tracker: Tracker) {
}
