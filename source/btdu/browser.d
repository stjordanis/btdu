/*
 * Copyright (C) 2020  Vladimir Panteleev <btdu@cy.md>
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public
 * License v2 as published by the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * General Public License for more details.
 *
 * You should have received a copy of the GNU General Public
 * License along with this program; if not, write to the
 * Free Software Foundation, Inc., 59 Temple Place - Suite 330,
 * Boston, MA 021110-1307, USA.
 */

/// ncurses interface for browsing results
module btdu.browser;

import core.stdc.config;
import core.stdc.errno;
import core.sys.posix.locale;
import core.time;

import std.algorithm.comparison;
import std.algorithm.iteration;
import std.algorithm.mutation;
import std.algorithm.searching;
import std.algorithm.sorting;
import std.array;
import std.conv;
import std.exception;
import std.path;
import std.string;

import deimos.ncurses;

import ae.utils.text;
import ae.utils.time : stdDur;

import btdu.common;
import btdu.state;
import btdu.paths;

struct Browser
{
	BrowserPath* currentPath;
	sizediff_t top; // Scroll offset (row number, in the content, corresponding to the topmost displayed line)
	sizediff_t contentAreaHeight; // Number of rows where scrolling content is displayed
	string selection;
	string[] items, info;
	bool done;

	enum Mode
	{
		browser,
		info,
		help,
	}
	Mode mode;

	enum SortMode
	{
		name,
		size,
	}
	SortMode sortMode;
	bool reverseSort, dirsFirst;

	void start()
	{
		setlocale(LC_CTYPE, "");
		initscr();

		timeout(0); // Use non-blocking read
		cbreak(); // Disable line buffering
		noecho(); // Disable keyboard echo
		keypad(stdscr, true); // Enable arrow keys
		curs_set(0); // Hide cursor

		currentPath = &browserRoot;
	}

	~this()
	{
		endwin();
	}

	@disable this(this);

	string message; MonoTime showMessageUntil;
	void showMessage(string s)
	{
		message = s;
		showMessageUntil = MonoTime.currTime() + (100.msecs * s.length);
	}

	void update()
	{
		int h, w;
		getmaxyx(stdscr, h, w); h++; w++;

		items = currentPath.children.keys;
		final switch (sortMode)
		{
			case SortMode.name:
				items.sort();
				break;
			case SortMode.size:
				items.multiSort!(
					(a, b) => currentPath.children[a].samples > currentPath.children[b].samples,
					(a, b) => a < b,
				);
				break;
		}
		if (reverseSort)
			items.reverse();
		if (dirsFirst)
			items.sort!(
				(a, b) => !!currentPath.children[a].children > !!currentPath.children[b].children,
				SwapStrategy.stable,
			);

		if (!selection && items.length)
			selection = items[0];
		if (!items.length && mode == Mode.browser && currentPath !is &browserRoot)
			mode = Mode.info;

		// Build info
		if (mode.among(Mode.browser, Mode.info))
		{
			info = null;

			char[] fullPath;
			{
				static Appender!(char[]) buf;
				buf.clear();
				buf.put(fsPath);
				bool recurse(BrowserPath *path)
				{
					string name = path.name;
					if (name.skipOver("\0"))
						switch (name)
						{
							case "DATA":
							case "UNREACHABLE":
								return true;
							default:
								return false;
						}
					if (path.parent)
						if (!recurse(path.parent))
							return false;
					buf.put('/');
					buf.put(name);
					return true;
				}
				if (recurse(currentPath))
					fullPath = buf.data;
			}

			info ~= ["", "--- Details: "];
			if (fullPath)
				info ~= "- Full path: " ~ cast(string)fullPath;
			info ~= "- Size: " ~ (browserRoot.samples
				? format!"~%s (%d sample%s)"(
					humanSize(currentPath.samples * totalSize / browserRoot.samples),
					currentPath.samples,
					currentPath.samples == 1 ? "" : "s",
				)
				: "-");
			info ~= "- Average query duration: " ~ (currentPath.samples
				? stdDur(currentPath.duration / currentPath.samples).toString()
				: "-");

			{
				string explanation = {
					if (currentPath is &browserRoot)
						return
							"Welcome to btdu. You are in the hierarchy root; " ~
							"results will be arranged according to their block group and profile, and then by path." ~
							"\n\n" ~
							"Use the arrow keys to navigate, press ? for help.";

					string name = currentPath.name;
					if (name.skipOver("\0"))
					{
						switch (name)
						{
							case "DATA":
								return
									"This node holds samples from chunks in the DATA block group, " ~
									"which mostly contains file data.";
							case "METADATA":
								return
									"This node holds samples from chunks in the METADATA block group, " ~
									"which contains btrfs internal metadata arranged in b-trees." ~
									"\n\n" ~
									"The contents of small files may be stored here, in line with their metadata." ~
									"\n\n" ~
									"The contents of METADATA chunks is opaque to btdu, so this node does not have children.";
							case "SYSTEM":
								return
									"This node holds samples from chunks in the SYSTEM block group " ~
									"which contains some core btrfs information, such as how to map physical device space to linear logical space or vice-versa." ~
									"\n\n" ~
									"The contents of SYSTEM chunks is opaque to btdu, so this node does not have children.";
							case "RAID0":
							case "RAID1":
							case "DUP":
							case "RAID10":
							case "RAID5":
							case "RAID6":
							case "RAID1C3":
							case "RAID1C4":
								return
									"This node holds samples from chunks in the " ~ name ~ " profile.";
							case "ERROR":
								return
									"This node represents sample points for which btdu encountered an error when attempting to query them." ~
									"\n\n" ~
									"Children of this node indicate the encountered error, and may have a more detailed explanation attached.";
							case "ROOT_TREE":
								return
									"This node holds samples with inodes contained in the BTRFS_ROOT_TREE_OBJECTID object." ~
									"\n\n" ~
									"These samples are not resolvable to paths, and most likely indicate some kind of metadata. " ~
									"(If you know, please tell me!)";
							case "NO_INODE":
								return
									"This node represents sample points for which btrfs successfully completed our request " ~
									"to look up inodes at the given logical offset, but did not actually return any inodes.";
							case "NO_PATH":
								return
									"This node represents sample points for which btrfs successfully completed our request " ~
									"to look up filesystem paths for the given inode, but did not actually return any paths.";
							case "UNREACHABLE":
								return
									"This node represents sample points in extents which are not used by any files.\n" ~
									"Despite not being directly used, these blocks are kept because another part of the extent they belong to is actually used by files." ~
									"\n\n" ~
									"This can happen if a large file is written in one go, and then later one block is overwritten - " ~
									"btrfs may keep the old extent which still contains the old copy of the overwritten block." ~
									"\n\n" ~
									"Defragmentation may reduce the amount of such unreachable blocks.";
							default:
								if (name.skipOver("TREE_"))
									return
										"This node holds samples with inodes contained in the tree #" ~ name ~ ", " ~
										"but btdu failed to resolve this tree number to an absolute path.";
								debug assert(false, "Unknown special node: " ~ name);
						}
					}

					if (currentPath.parent && currentPath.parent.name == "\0ERROR")
					{
						switch (name)
						{
							case "Unresolvable root":
								return
									"btdu failed to resolve this tree number to an absolute path.";
							default:
								if (name == errnoString!("logical ino", ENOENT))
									return
										"btrfs reports that there is nothing at the random sample location that btdu picked." ~
										"\n\n" ~
										"This most likely represents allocated but unused space, " ~
										"which could be reduced by running a balance on the DATA block group.";
								if (name == errnoString!("open", ENOENT))
									return
										"btdu failed to open the filesystem root containing an inode." ~
										"\n\n" ~
										"The most likely reason for this is that you didn't specify the path to the volume root when starting btdu, " ~
										"and instead specified the path to a subvolume or subdirectory." ~
										"\n\n" ~
										"You can descend into this node to see the path that btdu failed to open.";
						}
					}

					return null;
				}();

				if (explanation)
					info ~= ["", "--- Explanation: "] ~ explanation.verbatimWrap(w).replace("\n ", "\n").strip().split("\n");
			}

			bool showSeenAs;
			if (currentPath.seenAs.empty)
				showSeenAs = false;
			else
			if (fullPath is null && currentPath.seenAs.length == 1)
				showSeenAs = false; // Not a real file
			else
				showSeenAs = true;

			if (showSeenAs)
			{
				info ~= ["", "--- Shares data with: "];
				foreach (path; currentPath.seenAs.keys.sort)
					info ~= "- " ~ path.text;
			}

			if (mode == Mode.info && !info.length)
			{
				if (items.length)
					info ~= "  (no info for this node - press i or q to exit)";
				else
					info ~= "  (empty node)";
			}

			for (size_t i = 0; i < info.length; i++)
				if (info[i].length > w)
					info = info[0 .. i] ~ info[i][0 .. w] ~ info[i][w .. $] ~ info[i + 1 .. $];
		}

		// Scrolling and cursor upkeep
		{
			contentAreaHeight = h - 3;
			size_t contentHeight;
			final switch (mode)
			{
				case Mode.browser:
					contentHeight = items.length;
					contentAreaHeight -= min(info.length, contentAreaHeight / 2);
					break;
				case Mode.info:
					contentHeight = info.length;
					break;
				case Mode.help:
					contentHeight = help.length;
					break;
			}

			// Ensure there is no unnecessary space at the bottom
			if (top + contentAreaHeight > contentHeight)
				top = contentHeight - contentAreaHeight;
			// Ensure we are never scrolled "above" the first row
			if (top < 0)
				top = 0;

			final switch (mode)
			{
				case Mode.browser:
				{
					// Ensure the selected item is visible
					auto pos = selection && items ? items.countUntil(selection) : 0;
					top = top.clamp(
						pos - contentAreaHeight + 1,
						pos,
					);
					break;
				}
				case Mode.info:
				case Mode.help:
					break;
			}
		}

		// Rendering
		{
			erase();

			if (h < 10 || w < 32)
			{
				mvprintw(0, 0, "Window too small");
				refresh();
				return;
			}

			attron(A_REVERSE);
			mvhline(0, 0, ' ', w);
			mvprintw(0, 0, "btdu v" ~ btduVersion ~ " @ %s", fsPath.toStringz());
			if (paused)
				mvprintw(0, w - 10, " [PAUSED] ");

			mvhline(h - 1, 0, ' ', w);
			if (message && MonoTime.currTime < showMessageUntil)
				mvprintw(h - 1, 0, " %s", message.toStringz);
			else
			{
				auto resolution = browserRoot.samples
					? "~" ~ (totalSize / browserRoot.samples).humanSize()
					: "-";
				mvprintw(h - 1, 0,
					" Samples: %lld  Resolution: %s",
					cast(cpp_longlong)browserRoot.samples,
					resolution.toStringz()
				);
			}
			attroff(A_REVERSE);

			if (mode.among(Mode.browser, Mode.info))
			{
				auto displayedPath = currentPath is &browserRoot ? "/" : currentPath.pointerWriter.text;
				auto prefix = ["", "INFO: "][mode];
				auto maxPathWidth = w - 8 - prefix.length;
				if (displayedPath.length > maxPathWidth)
					displayedPath = "..." ~ displayedPath[$ - (maxPathWidth - 3) .. $];

				mvhline(1, 0, '-', w);
				mvprintw(1, 3,
					" %s%s ",
					prefix.ptr,
					displayedPath.toStringz()
				);
			}
		}

		final switch (mode)
		{
			case Mode.browser:
			{
				auto mostSamples = currentPath.children.byValue.fold!((a, b) => max(a, b.samples))(0UL);

				foreach (i, item; items)
				{
					auto y = cast(int)(i - top);
					if (y < 0 || y >= contentAreaHeight)
						continue;
					y += 2;

					if (item is selection)
						attron(A_REVERSE);
					else
						attroff(A_REVERSE);
					mvhline(y, 0, ' ', w);

					auto child = currentPath.children[item];
					char[10] bar;
					if (mostSamples)
					{
						auto barPos = 10 * child.samples / mostSamples;
						bar[0 .. barPos] = '#';
						bar[barPos .. $] = ' ';
					}
					else
						bar[] = '-';

					auto size = browserRoot.samples
						? "~" ~ humanSize(child.samples * totalSize / browserRoot.samples)
						: "?";
					auto displayedItem = child.humanName;
					if (child.name.startsWith("\0"))
						displayedItem = "<" ~ displayedItem ~ ">";
					auto maxItemWidth = w - 27;
					if (displayedItem.length > maxItemWidth)
					{
						auto leftLength = (maxItemWidth - "...".length) / 2;
						auto rightLength = maxItemWidth - "...".length - leftLength;
						displayedItem =
							displayedItem[0 .. leftLength] ~ "..." ~
							displayedItem[$ - rightLength .. $];
					}
					mvprintw(y, 0,
						"%12s [%.10s] %c%s",
						size.toStringz(),
						bar.ptr,
						child.children is null ? ' ' : '/',
						displayedItem.toStringz(),
					);
				}
				attroff(A_REVERSE);

				foreach (i, line; info)
				{
					auto y = cast(int)(contentAreaHeight + i);
					y += 2;
					if (y == h - 2 && i + 1 < info.length)
					{
						mvprintw(y, 0, " --- more - press i to view --- ");
						break;
					}
					mvhline(y, 0, i != 1 ? ' ' : '-', w);
					mvprintw(y, 0, "%s", line.toStringz());
				}
				break;
			}

			case Mode.info:
			case Mode.help:
				foreach (i, line; mode == Mode.info ? info : help)
				{
					auto y = cast(int)(i - top);
					if (y < 0 || y >= contentAreaHeight)
						continue;
					y += 2;
					mvprintw(y, 0, "%s", line.toStringz());
				}
				break;
		}

		refresh();
	}

	void moveCursor(sizediff_t delta)
	{
		if (!items.length)
			return;
		auto pos = items.countUntil(selection);
		if (pos < 0)
			return;
		pos += delta;
		if (pos < 0)
			pos = 0;
		if (pos > items.length - 1)
			pos = items.length - 1;
		selection = items[pos];
	}

	/// Pausing has the following effects:
	/// 1. We sent a SIGSTOP to subprocesses, so that they stop working ASAP.
	/// 2. We immediately stop reading subprocess output, so that the UI stops updating.
	/// 3. We display the paused state in the UI.
	void togglePause()
	{
		paused = !paused;
		foreach (ref subprocess; subprocesses)
			subprocess.pause(paused);
	}

	void setSort(SortMode mode)
	{
		if (sortMode == mode)
			reverseSort = !reverseSort;
		else
		{
			sortMode = mode;
			reverseSort = false;
		}
	}

	bool handleInput()
	{
		auto ch = getch();

		if (ch == ERR)
			return false; // no events - would have blocked
		else
			message = null;

		switch (ch)
		{
			case 'p':
				togglePause();
				return true;
			case '?':
			case KEY_F0 + 1:
				mode = Mode.help;
				top = 0;
				break;
			default:
				// Proceed according to mode
		}

		final switch (mode)
		{
			case Mode.browser:
				switch (ch)
				{
					case KEY_LEFT:
					case 'h':
					case '<':
						if (currentPath.parent)
						{
							selection = currentPath.name;
							currentPath = currentPath.parent;
							top = 0;
						}
						else
							showMessage("Already at top-level");
						break;
					case KEY_RIGHT:
					case '\n':
						if (selection)
						{
							currentPath = currentPath.children[selection];
							selection = null;
							top = 0;
						}
						else
							showMessage("Nowhere to descend into");
						break;
					case KEY_UP:
					case 'k':
						moveCursor(-1);
						break;
					case KEY_DOWN:
					case 'j':
						moveCursor(+1);
						break;
					case KEY_PPAGE:
						moveCursor(-contentAreaHeight);
						break;
					case KEY_NPAGE:
						moveCursor(+contentAreaHeight);
						break;
					case KEY_HOME:
						moveCursor(-items.length);
						break;
					case KEY_END:
						moveCursor(+items.length);
						break;
					case 'i':
						mode = Mode.info;
						top = 0;
						break;
					case 'q':
						done = true;
						break;
					case 'n':
						setSort(SortMode.name);
						break;
					case 's':
						setSort(SortMode.size);
						break;
					case 't':
						dirsFirst = !dirsFirst;
						break;
					default:
						// TODO: show message
						break;
				}
				break;

			case Mode.info:
				switch (ch)
				{
					case KEY_LEFT:
					case 'h':
					case '<':
						mode = Mode.browser;
						if (currentPath.parent)
						{
							selection = currentPath.name;
							currentPath = currentPath.parent;
							top = 0;
						}
						break;
					case 'q':
						if (items.length)
							goto case 'i';
						else
							goto case KEY_LEFT;
					case 'i':
						mode = Mode.browser;
						top = 0;
						break;
					case KEY_UP:
					case 'k':
						top += -1;
						break;
					case KEY_DOWN:
					case 'j':
						top += +1;
						break;
					case KEY_PPAGE:
						top += -contentAreaHeight;
						break;
					case KEY_NPAGE:
						top += +contentAreaHeight;
						break;
					case KEY_HOME:
						top -= info.length;
						break;
					case KEY_END:
						top += info.length;
						break;
					default:
						// TODO: show message
						break;
				}
				break;

			case Mode.help:
				switch (ch)
				{
					case 'q':
						mode = Mode.browser;
						top = 0;
						break;

					case KEY_UP:
					case 'k':
						top += -1;
						break;
					case KEY_DOWN:
					case 'j':
						top += +1;
						break;
					case KEY_PPAGE:
						top += -contentAreaHeight;
						break;
					case KEY_NPAGE:
						top += +contentAreaHeight;
						break;
					case KEY_HOME:
						top -= help.length;
						break;
					case KEY_END:
						top += help.length;
						break;
					default:
						// TODO: show message
						break;
				}
				break;
		}

		return true;
	}
}

private:

string humanSize(ulong size)
{
	static immutable prefixChars = " KMGTPEZY";
	double fpSize = size;
	size_t power = 0;
	while (fpSize > 1024 && power + 1 < prefixChars.length)
	{
		fpSize /= 1024;
		power++;
	}
	return format("%3.1f %s%sB", fpSize, prefixChars[power], prefixChars[power] == ' ' ? ' ' : 'i');
}

/// Helper type for formatting pointers without passing their contents by-value.
/// Helps preserve the SubPath invariant (which would be broken by copying).
struct PointerWriter(T)
{
	T* ptr;
	void toString(scope void delegate(const(char)[]) sink) const
	{
		ptr.toString(sink);
	}
}
PointerWriter!T pointerWriter(T)(T* ptr) { return PointerWriter!T(ptr); }

/// Allow matching error messages with strerror strings
string errnoString(string s, int errno)()
{
	static string result;
	if (!result)
		result = new ErrnoException(s, errno).msg;
	return result;
}

static immutable string[] help = q"EOF
btdu - the sampling disk usage profiler for btrfs
-------------------------------------------------

Keys:

      F1, ? - Show this help screen
      Up, k - Move cursor up
    Down, j - Move cursor down
Right/Enter - Open selected node
 Left, <, h - Return to parent node
          p - Pause/resume
          n - Sort by name (ascending/descending)
          s - Sort by size (ascending/descending)
          t - Toggle dirs before files when sorting
          i - Expand/collapse information panel
          q - Close information panel or quit btdu

https://github.com/CyberShadow/btdu
Created by: Vladimir Panteleev <https://cy.md/>
EOF".splitLines;
