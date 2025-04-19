package nattorrent

import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"

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

	if len(os.args) == 1 {
		fmt.eprintln("Please specify a torrent file.")
	} else if len(os.args) > 2 {
		fmt.eprintln("Please specify only one torrent file.")
	} else {
		torrent_file := os.args[1]
		torrent := open_file(torrent_file)
		defer torrent_destroy(torrent)

		tracker, err := tracker_init(&torrent)
		defer tracker_destroy(tracker)
		if err != nil {
			fmt.println("Tracker error:", err)
			panic("Could not connect to tracker")
		}

		// initial announce
		tracker_announce(&tracker)
		tracker.state = .Active

		// and response
		tracker_response(&tracker)

		// start listening for peer messages
		listen_ep := net.Endpoint {
			address = net.IP4_Any,
			port = 6881,
		}
		listen_sock: net.TCP_Socket
		listen_sock, err = net.listen_tcp(listen_ep)
		if err != nil {
			fmt.eprintln("Listen socket error: ", err)
			panic("could not open socket for incoming messages")
		}

		// handshake to send peers upon connecting
		handshake := gen_handshake(tracker)
		defer delete(handshake)
		bytes_sent: int

		for &peer in tracker.peers {
			peer.socket, err = net.dial_tcp(peer.endpoint)
			if err != nil {
				fmt.eprintln("Could not connect to peer", peer.endpoint, " error:", err)
			}

			bytes_sent, err = net.send_tcp(peer.socket, handshake)
			if bytes_sent != len(handshake) || err != nil {
				fmt.eprintln("failed sending handshake to peer", peer.endpoint, "bytes sent:", bytes_sent, "err:", err)
			}
		}

		// when stopping, inform the tracker
		tracker.state = .Stopped
		tracker_announce(&tracker)
	}

	free_all(context.temp_allocator)
}
