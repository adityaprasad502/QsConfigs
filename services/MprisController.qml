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
	property int _playerFilterRevision: 0;
	property var _pauseTimestamps: ({});
	property list<MprisPlayer> players: {
		_playerFilterRevision;
		return Mpris.players.values.filter(player => isRealPlayer(player));
	}
	property MprisPlayer trackedPlayer: null;
	property MprisPlayer activePlayer: (trackedPlayer && isRealPlayer(trackedPlayer)) ? trackedPlayer : (root.players[0] ?? null);
	signal trackChanged(reverse: bool);

	onPlayersChanged: Qt.callLater(root.updateBestPlayer);
	onHasActiveDesktopSpotifyChanged: {
		root._playerFilterRevision++;
		Qt.callLater(root.updateBestPlayer);
	}

	property bool __reverse: false;

	property var activeTrack;

	readonly property bool hasActivePlasmaIntegration: Mpris.players.values.some(
		p => p.dbusName?.startsWith('org.mpris.MediaPlayer2.plasma-browser-integration')
	)
	readonly property bool hasActiveDesktopSpotify: Mpris.players.values.some(
		p => (p.dbusName || "").toLowerCase().includes("mediaplayer2.spotify")
	)
	function isLive(player) {
		if (!player) return false;
		let len = player.length || 0;
		let canSeek = player.canSeek ?? false;
		let lenSupported = player.lengthSupported ?? true;
		return !lenSupported || len <= 0 || !canSeek;
	}

	function isKdeConnectPlayer(player) {
		return !!player && (player.dbusName || "").toLowerCase().includes("kdeconnect");
	}

	function isBrowserPlayer(player) {
		if (!player) return false;
		let dbus = (player.dbusName || "").toLowerCase();
		let identity = (player.identity || "").toLowerCase();
		return dbus.includes("chromium") || dbus.includes("chrome") || dbus.includes("firefox")
			|| dbus.includes("brave") || dbus.includes("edge") || dbus.includes("vivaldi")
			|| dbus.includes("plasma-browser-integration")
			|| identity.includes("chrome") || identity.includes("firefox") || identity.includes("chromium")
			|| identity.includes("brave") || identity.includes("web browser");
	}

	function isNativeSpotifyPlayer(player) {
		if (!player) return false;
		let dbus = (player.dbusName || "").toLowerCase();
		let identity = (player.identity || "").toLowerCase();
		return (dbus.includes("mediaplayer2.spotify") || identity === "spotify") && !root.isKdeConnectPlayer(player);
	}

	function isFinished(player) {
		if (!player || root.isLive(player)) return false;
		if (root.isNativeSpotifyPlayer(player)) return false;
		let len = player.length || 0;
		let pos = player.position || 0;
		if (len > 0 && pos >= (len - 0.5)) return true;
		let isKde = root.isKdeConnectPlayer(player);
		let isBrowser = root.isBrowserPlayer(player);
		let isPlaying = player.isPlaying || player.playbackState === MprisPlaybackState.Playing;
		if ((isKde || isBrowser) && !isPlaying && pos <= 0.5) return true;
		return false;
	}

	function _isPausedStale(player, maxSeconds) {
		if (!player) return false;
		let key = player.uniqueId || player.dbusName;
		let ts = root._pauseTimestamps[key];
		if (!ts) return false;
		return (Date.now() - ts) > ((maxSeconds || 60) * 1000);
	}

	function isRealPlayer(player) {
		if (!player) return false;
		if (!Config.options.media.filterDuplicatePlayers) {
			return true;
		}

		let dbus = (player.dbusName || "").toLowerCase();
		let identity = (player.identity || "").toLowerCase();
		let isKde = root.isKdeConnectPlayer(player);
		let isBrowser = root.isBrowserPlayer(player);

		if (hasActivePlasmaIntegration && (dbus.startsWith('org.mpris.mediaplayer2.firefox') || dbus.startsWith('org.mpris.mediaplayer2.chromium'))) {
			return false;
		}

		if (dbus.startsWith('org.mpris.mediaplayer2.playerctld') || (dbus.endsWith('.mpd') && !dbus.endsWith('mediaplayer2.mpd'))) {
			return false;
		}

		let title = (player.trackTitle || "").trim().toLowerCase();
		let artist = (player.trackArtist || "").trim();
		let isPlaying = player.isPlaying || player.playbackState === MprisPlaybackState.Playing;

		if (!isPlaying && (title === "" || title === "untitled") && artist === "") {
			return false;
		}

		if (isKde && hasActiveDesktopSpotify && identity.includes("spotify")) {
			return false;
		}

		// Evict finished tracks or unstarted idle sessions
		if (root.isFinished(player)) {
			return false;
		}

		// Evict transient players paused mid-track for too long
		if ((isKde || isBrowser) && !isPlaying && root._isPausedStale(player, 60)) {
			return false;
		}

		return true;
	}

	function getPlayerScore(p) {
		if (!p) return -9999;
		let score = 0;
		let isPlaying = p.isPlaying || p.playbackState === MprisPlaybackState.Playing;
		if (isPlaying) score += 100;
		let len = p.length || 0;
		let pos = p.position || 0;
		// If track has clearly finished playing, heavily penalize it so active tracks win
		if (len > 0 && pos >= (len - 0.5)) {
			score -= 150;
		} else if (isPlaying && pos > 0) {
			score += 20; // actively progressing
		}
		let dbus = (p.dbusName || "").toLowerCase();
		// Prefer local native players over remote proxies like kdeconnect
		if (!dbus.includes("kdeconnect")) {
			score += 40;
		}
		if (p.trackArtUrl && p.trackArtUrl.length > 0) score += 10;
		if (p.trackTitle && p.trackTitle.trim().length > 0) score += 10;
		if (p.trackArtist && p.trackArtist.trim().length > 0) score += 5;
		return score;
	}

	function getBestPlayer() {
		let best = null;
		let bestScore = -99999;
		for (const player of root.players) {
			if (!root.isRealPlayer(player)) {
				continue;
			}
			let score = root.getPlayerScore(player);
			if (score > bestScore) {
				bestScore = score;
				best = player;
			}
		}
		return best;
	}

	function updateBestPlayer() {
		let best = root.getBestPlayer();
		if (best !== root.trackedPlayer) {
			root.trackedPlayer = best;
		}
	}

	// Watchdog for players (e.g. browsers, KDE Connect) that don't emit DBus signals
	// when reaching track end or when the remote app is closed without sending a pause packet.
	Timer {
		interval: 1000
		repeat: true
		running: root.activePlayer != null
		onTriggered: {
			let p = root.activePlayer;
			if (!p) return;
			if (!root.isRealPlayer(p)) {
				root._playerFilterRevision++;
				root.updateBestPlayer();
			}
		}
	}

	// Player tracking
	Instantiator {
		model: Mpris.players.values;

		Connections {
			required property MprisPlayer modelData;
			target: modelData;

			Component.onCompleted: {
				Qt.callLater(root.updateBestPlayer);
			}

			Component.onDestruction: {
				if (root.trackedPlayer === modelData) {
					root.trackedPlayer = null;
				}
				Qt.callLater(root.updateBestPlayer);
			}

			function evaluateState() {
				let key = modelData.uniqueId || modelData.dbusName;
				let isPlaying = modelData.isPlaying || modelData.playbackState === MprisPlaybackState.Playing;
				if (isPlaying) {
					delete root._pauseTimestamps[key];
				} else if (!root._pauseTimestamps[key]) {
					root._pauseTimestamps[key] = Date.now();
				}
				let real = root.isRealPlayer(modelData);
				let inList = root.players.includes(modelData);
				if (real !== inList) {
					Qt.callLater(() => root._playerFilterRevision++);
				}
				if (modelData.isPlaying) {
					if (!root.trackedPlayer || !root.trackedPlayer.isPlaying || root.getPlayerScore(modelData) >= root.getPlayerScore(root.trackedPlayer)) {
						root.trackedPlayer = modelData;
					}
				} else if (root.trackedPlayer === modelData) {
					root.updateBestPlayer();
				}
			}

			function onPlaybackStateChanged() {
				evaluateState();
			}

			function onPostTrackChanged() {
				evaluateState();
			}

			function onTrackTitleChanged() {
				evaluateState();
			}

			function onPositionChanged() {
				let len = modelData.length || 0;
				let pos = modelData.position || 0;
				if (len > 0 && pos >= (len - 0.5)) {
					evaluateState();
				}
			}
		}
	}

	Connections {
		target: activePlayer

		function onPostTrackChanged() {
			root.updateTrack();
		}

		function onTrackTitleChanged() {
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
			if (root.activePlayer && root.activeTrack && root.activePlayer.uniqueId == root.activeTrack.uniqueId && root.activePlayer.trackArtUrl != root.activeTrack.artUrl) {
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
