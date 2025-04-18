package nattorrent

import "core:fmt"
import "core:mem"
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

	// load torrent file
	if len(os.args) == 1 {
		fmt.eprintln("Please specify a torrent file.")
	} else if len(os.args) > 2 {
		fmt.eprintln("Please specify only one torrent file.")
	} else {
		torrent_file := os.args[1]
		torrent := open_file(torrent_file)
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
	}

	free_all(context.temp_allocator)
}
