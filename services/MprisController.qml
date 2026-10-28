pragma Singleton
pragma ComponentBehavior: Bound

// From https://git.outfoxxed.me/outfoxxed/nixnew
// It does not have a license, but the author is okay with redistribution.

import QtQml.Models
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.modules.common
import qs.modules.common.functions

/**
 * A service that provides easy access to the active Mpris player.
 */
Singleton {
	id: root;
	property list<MprisPlayer> players: Mpris.players.values.filter(player => isRealPlayer(player));
	property MprisPlayer trackedPlayer: null;
	property MprisPlayer activePlayer: trackedPlayer ?? root.players[0] ?? null;
	signal trackChanged(reverse: bool);

	property bool __reverse: false;

	property var activeTrack;

	readonly property bool hasActivePlasmaIntegration: Mpris.players.values.some(
		p => p.dbusName?.startsWith('org.mpris.MediaPlayer2.plasma-browser-integration')
	)
	function isRealPlayer(player) {
        if (!player) return false;
        if (!Config.options.media.filterDuplicatePlayers) {
            return true;
        }

        let dbus = (player.dbusName || "").toLowerCase();

        if (hasActivePlasmaIntegration && (dbus.startsWith('org.mpris.mediaplayer2.firefox') || dbus.startsWith('org.mpris.mediaplayer2.chromium'))) {
            return false;
        }

        if (dbus.startsWith('org.mpris.mediaplayer2.playerctld')) {
            return false;
        }

        if (dbus.endsWith('.mpd') && !dbus.endsWith('mediaplayer2.mpd')) {
            return false;
        }

        let title = (player.trackTitle || "").trim().toLowerCase();
        let artist = (player.trackArtist || "").trim();
        let isPlaying = player.isPlaying || player.playbackState === MprisPlaybackState.Playing;
        if (!isPlaying && (title === "" || title === "untitled") && artist === "") {
            return false;
        }

        return true;
    }

	// Original stuff from fox below
	Instantiator {
		model: root.players;

		Connections {
			required property MprisPlayer modelData;
			target: modelData;

			Component.onCompleted: {
				if (root.trackedPlayer == null || modelData.isPlaying) {
					root.trackedPlayer = modelData;
				}
			}

			Component.onDestruction: {
				if (root.trackedPlayer == null || !root.trackedPlayer.isPlaying) {
					for (const player of root.players) {
						if (player.isPlaying) {
							root.trackedPlayer = player;
							break;
						}
					}

					if (trackedPlayer == null && root.players.length != 0) {
						trackedPlayer = root.players[0];
					}
				}
			}

			function onPlaybackStateChanged() {
				if (modelData.isPlaying) {
					root.trackedPlayer = modelData;
				} else if (root.trackedPlayer === modelData) {
					for (const player of root.players) {
						if (player.isPlaying) {
							root.trackedPlayer = player;
							break;
						}
					}
				}
			}
		}
	}

	Connections {
		target: activePlayer

		function onPostTrackChanged() {
			root.updateTrack();
		}

		function onTrackArtistChanged() {
			root.updateTrack();
		}

		function onTrackArtistsChanged() {
			root.updateTrack();
		}

		function onTrackArtUrlChanged() {
			// console.log("arturl:", activePlayer.trackArtUrl)
			// root.updateTrack();
			if (root.activePlayer.uniqueId == root.activeTrack.uniqueId && root.activePlayer.trackArtUrl != root.activeTrack.artUrl) {
				// cantata likes to send cover updates *BEFORE* updating the track info.
				// as such, art url changes shouldn't be able to break the reverse animation
				const r = root.__reverse;
				root.updateTrack();
				root.__reverse = r;

			}
		}
	}

	onActivePlayerChanged: this.updateTrack();

	function getPlayerArtists(player) {
		if (!player) return "";

		let list = [];

		let xesam = player.metadata ? player.metadata["xesam:artist"] : null;
		if (Array.isArray(xesam) && xesam.length > 0) {
			for (let i = 0; i < xesam.length; i++) {
				let a = String(xesam[i] || "").trim();
				let cleaned = StringUtils.cleanMusicArtist(a) || a;
				if (cleaned.length > 0 && !list.includes(cleaned)) {
					list.push(cleaned);
				}
			}
		} else if (Array.isArray(player.trackArtists) && player.trackArtists.length > 0) {
			for (let i = 0; i < player.trackArtists.length; i++) {
				let a = String(player.trackArtists[i] || "").trim();
				let cleaned = StringUtils.cleanMusicArtist(a) || a;
				if (cleaned.length > 0 && !list.includes(cleaned)) {
					list.push(cleaned);
				}
			}
		} else {
			let single = (typeof player.trackArtists === "string" && player.trackArtists.trim().length > 0)
				? player.trackArtists
				: (player.trackArtist || "");
			if (single) {
				let parts = single.split(/\s*(?:,|&|\band\b|\/|;)\s*/i).map(s => s.trim()).filter(Boolean);
				if (parts.length > 1) {
					for (let i = 0; i < parts.length; i++) {
						let cleaned = StringUtils.cleanMusicArtist(parts[i]) || parts[i];
						if (cleaned.length > 0 && !list.includes(cleaned)) {
							list.push(cleaned);
						}
					}
				} else {
					let cleaned = StringUtils.cleanMusicArtist(single) || single;
					if (cleaned.length > 0) list.push(cleaned);
				}
			}
		}

		let titleFeat = StringUtils.extractFeaturedArtists(player.trackTitle);
		for (let f = 0; f < titleFeat.length; f++) {
			let fa = StringUtils.cleanMusicArtist(titleFeat[f]) || titleFeat[f];
			let exists = list.some(item => {
				let iLower = item.toLowerCase();
				let fLower = fa.toLowerCase();
				return iLower === fLower || iLower.includes(fLower) || fLower.includes(iLower);
			});
			if (!exists && fa.length > 0) {
				list.push(fa);
			}
		}

		return list.join(", ");
	}

	function updateTrack() {
		//console.log(`update: ${this.activePlayer?.trackTitle ?? ""} : ${this.activePlayer?.trackArtists}`)
		this.activeTrack = {
			uniqueId: this.activePlayer?.uniqueId ?? 0,
			artUrl: this.activePlayer?.trackArtUrl ?? "",
			title: this.activePlayer?.trackTitle || Translation.tr("Unknown Title"),
			artist: root.getPlayerArtists(this.activePlayer) || Translation.tr("Unknown Artist"),
			album: this.activePlayer?.trackAlbum || Translation.tr("Unknown Album"),
		};

		this.trackChanged(__reverse);
		this.__reverse = false;
	}

	property bool isPlaying: this.activePlayer && this.activePlayer.isPlaying;
	property bool canTogglePlaying: this.activePlayer?.canTogglePlaying ?? false;
	function togglePlaying() {
		if (this.canTogglePlaying) this.activePlayer.togglePlaying();
	}

	property bool canGoPrevious: this.activePlayer?.canGoPrevious ?? false;
	function previous() {
		if (this.canGoPrevious) {
			this.__reverse = true;
			this.activePlayer.previous();
		}
	}

	property bool canGoNext: this.activePlayer?.canGoNext ?? false;
	function next() {
		if (this.canGoNext) {
			this.__reverse = false;
			this.activePlayer.next();
		}
	}

	property bool canChangeVolume: this.activePlayer && this.activePlayer.volumeSupported && this.activePlayer.canControl;

	property bool loopSupported: this.activePlayer && this.activePlayer.loopSupported && this.activePlayer.canControl;
	property var loopState: this.activePlayer?.loopState ?? MprisLoopState.None;
	function setLoopState(loopState: var) {
		if (this.loopSupported) {
			this.activePlayer.loopState = loopState;
		}
	}

	property bool shuffleSupported: this.activePlayer && this.activePlayer.shuffleSupported && this.activePlayer.canControl;
	property bool hasShuffle: this.activePlayer?.shuffle ?? false;
	function setShuffle(shuffle: bool) {
		if (this.shuffleSupported) {
			this.activePlayer.shuffle = shuffle;
		}
	}

	function setActivePlayer(player: MprisPlayer) {
		const targetPlayer = player ?? Mpris.players.values[0];
		console.log(`[Mpris] Active player ${targetPlayer} << ${activePlayer}`)

		if (targetPlayer && this.activePlayer) {
			this.__reverse = Mpris.players.values.indexOf(targetPlayer) < Mpris.players.values.indexOf(this.activePlayer);
		} else {
			// always animate forward if going to null
			this.__reverse = false;
		}

		this.trackedPlayer = targetPlayer;
	}

	IpcHandler {
		target: "mpris"

		function pauseAll(): void {
			for (const player of Mpris.players.values) {
				if (player.canPause) player.pause();
			}
		}

		function playPause(): void { root.togglePlaying(); }
		function previous(): void { root.previous(); }
		function next(): void { root.next(); }
	}
}
