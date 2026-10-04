#!/usr/bin/env node
// Real-browser check of the exported Web build (Playwright + Chromium; dev tool only).
//   python3 tools/serve_web.py &                       # builds/web at /midnight-cat-delivery/
//   NODE_PATH="$(npm root -g)" node tools/browser_test.cjs [baseUrl] [outDir]
// Game state is observed through the read-only ?qa=1 snapshot (window.mcdQA).
// Keyboard/mouse go through Playwright; touch goes through CDP Input.dispatchTouchEvent
// (real browser TouchEvents in mobile emulation, not a physical phone).
'use strict';
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const BASE = process.argv[2] || 'http://localhost:8060/midnight-cat-delivery/';
const OUT = process.argv[3] || path.join(__dirname, '..', 'builds', 'qa');
const ONLY = process.env.ONLY || '';
fs.mkdirSync(OUT, { recursive: true });
const LAUNCH = { args: ['--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', '--use-angle=swiftshader'] };
// Software WebGL is fill-rate bound; desktop runs render at half resolution (CSS size unchanged).
const DESKTOP = { viewport: { width: 1280, height: 800 }, deviceScaleFactor: 0.5 };

let failed = 0;
const summary = [];
function check(cond, msg, extra) {
	const ok = !!cond;
	if (!ok) failed++;
	summary.push({ ok, msg });
	console.log((ok ? '  ok    ' : '  FAIL  ') + msg + (extra !== undefined ? '  ' + JSON.stringify(extra) : ''));
	return ok;
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const flat = (a, b) => Math.hypot(a.pos[0] - b.pos[0], a.pos[2] - b.pos[2]);
const hspeed = (s) => Math.hypot(s.vel[0], s.vel[2]);
const angDiff = (a, b) => Math.atan2(Math.sin(a - b), Math.cos(a - b));

async function qa(page) {
	return page.evaluate(() => (window.mcdQA ? JSON.parse(window.mcdQA) : null));
}
// Wait for game time to pass: N physics steps (60 per game second). Rendering here is
// CPU-emulated WebGL and can be very slow, so tests never rely on wall-clock sleeps.
async function steps(page, n, timeout = 60000) {
	const s0 = await qa(page);
	return waitQA(page, (q) => q.physics_frame >= s0.physics_frame + n, timeout, 10);
}
async function frames(page, n = 1, timeout = 30000) {
	const s0 = await qa(page);
	return waitQA(page, (q) => q.frame >= s0.frame + n, timeout, 5);
}
async function waitQA(page, pred, timeout = 10000, step = 30) {
	const t0 = Date.now();
	let s = null;
	while (Date.now() - t0 < timeout) {
		s = await qa(page);
		if (s && pred(s)) return s;
		await sleep(step);
	}
	return s;
}
function track(page) {
	const t = { errors: [], bad: [] };
	page.on('pageerror', (e) => t.errors.push(String(e)));
	page.on('console', (m) => { if (m.type() === 'error') t.errors.push(m.text()); });
	page.on('response', (r) => { if (r.status() >= 400) t.bad.push(r.status() + ' ' + r.url()); });
	page.on('requestfailed', (r) => t.bad.push('failed ' + r.url() + ' ' + ((r.failure() || {}).errorText || '')));
	return t;
}
async function canvasRect(page) {
	return page.evaluate(() => document.getElementById('canvas').getBoundingClientRect().toJSON());
}
// Viewport (Godot canvas) coordinates -> CSS pixels.
async function toCss(page, s, x, y) {
	const r = await canvasRect(page);
	return { x: r.x + (x * r.width) / s.vp[0], y: r.y + (y * r.height) / s.vp[1], k: r.width / s.vp[0] };
}
async function hudCenter(page, s, label) {
	const b = s.hud_buttons[label];
	if (!b) return null;
	return toCss(page, s, b[0] + b[2] / 2, b[1] + b[3] / 2);
}
async function clickHud(page, s, label) {
	const c = await hudCenter(page, s, label);
	if (!c) return false;
	await page.mouse.click(c.x, c.y);
	return true;
}

async function startGame(page, label) {
	const t0 = Date.now();
	await page.goto(BASE + '?qa=1');
	check(await page.locator('#screen-start').isVisible() && await page.locator('#btn-start').isVisible(),
		`${label}: start screen shows title, goal, start button and controls`);
	const note = await page.locator('#size-note').textContent();
	check(/MB/.test(note || ''), `${label}: download size shown from real file sizes`, note);
	await page.screenshot({ path: path.join(OUT, `${label}-1-start.png`) });
	await page.click('#btn-start');
	const loadingText = await page.locator('#loading-text').textContent().catch(() => '');
	const s = await waitQA(page, (q) => q.state === 'playing', 180000, 250);
	check(s && s.state === 'playing', `${label}: engine loaded and game is playing`, { ms: Date.now() - t0, loading: loadingText });
	check(await page.locator('#screen-loading').isHidden(), `${label}: loading screen removed after start`);
	return s;
}

// ------------------------------------------------------------ keyboard driving helpers
function keysFor(dx, dz, yaw) {
	const lx = dx * Math.cos(yaw) - dz * Math.sin(yaw);
	const lz = dx * Math.sin(yaw) + dz * Math.cos(yaw);
	const n = Math.hypot(lx, lz) || 1;
	const k = new Set();
	if (lz / n < -0.38) k.add('KeyW');
	if (lz / n > 0.38) k.add('KeyS');
	if (lx / n > 0.38) k.add('KeyD');
	if (lx / n < -0.38) k.add('KeyA');
	return k;
}
async function setKeys(page, held, want) {
	for (const k of [...held]) if (!want.has(k)) { await page.keyboard.up(k); held.delete(k); }
	for (const k of want) if (!held.has(k)) { await page.keyboard.down(k); held.add(k); }
}
async function kbWalkTo(page, tx, tz, tol = 0.1, extra = [], timeout = 120000) {
	const held = new Set();
	const t0 = Date.now();
	while (Date.now() - t0 < timeout) {
		const s = await qa(page);
		const dx = tx - s.pos[0];
		const dz = tz - s.pos[2];
		const d = Math.hypot(dx, dz);
		if (d < tol) break;
		const want = keysFor(dx, dz, s.cam_yaw);
		for (const e of extra) want.add(e);
		await setKeys(page, held, want);
		if (d < 0.6) {
			// Close: one-frame taps, then let the cat settle, so slow frames cannot overshoot.
			await frames(page, 1);
			await setKeys(page, held, new Set());
			await waitQA(page, (q) => hspeed(q) < 0.05, 20000, 10);
		} else {
			await frames(page, 1);
		}
	}
	await setKeys(page, held, new Set());
	const s = await waitQA(page, (q) => hspeed(q) < 0.03, 20000, 10);
	return Math.hypot(tx - s.pos[0], tz - s.pos[2]);
}
// ------------------------------------------------------------ desktop
async function desktop(browser) {
	console.log('-- desktop 1280x800 (mouse + keyboard)');
	const ctx = await browser.newContext(DESKTOP);
	const page = await ctx.newPage();
	const t = track(page);
	let s = await startGame(page, 'desktop');
	check(!s.captured, 'pointer is not captured automatically on start');
	check(!s.touch, 'touch buttons are hidden on a mouse-first desktop');
	check(await page.evaluate(() => document.activeElement && document.activeElement.id === 'canvas'), 'canvas has keyboard focus');

	let a = await qa(page);
	await page.keyboard.down('KeyW');
	await steps(page, 54);
	let b = await qa(page);
	check(flat(a, b) > 0.8 && ['walk', 'run'].includes(b.move_state), 'W walks forward', { moved: +flat(a, b).toFixed(2), state: b.move_state });
	await page.keyboard.up('KeyW');
	await steps(page, 30);
	let c = await qa(page);
	await steps(page, 24);
	let c2 = await qa(page);
	check(hspeed(c) < 0.05 && flat(c, c2) < 0.005, 'releasing W stops without sliding');

	const j0 = c2.jumps;
	await page.keyboard.down('Space');
	await steps(page, 22);
	let d = await qa(page);
	check(d.charging && d.charge > 0.3 && d.jumps === j0 && d.move_state === 'crouch', 'holding Space crouches and charges', { charge: +d.charge.toFixed(2) });
	await page.keyboard.up('Space');
	let e = await waitQA(page, (q) => q.jumps === j0 + 1 && !q.on_floor, 20000, 5);
	check(e && e.jumps === j0 + 1 && e.move_state === 'air', 'releasing Space leaps once (air state shown)');
	await waitQA(page, (q) => q.on_floor, 30000);
	await steps(page, 24);
	let f = await qa(page);
	check(f.jumps === j0 + 1 && f.on_floor, 'lands; no extra jump');
	check(await page.evaluate(() => window.scrollY === 0 && document.scrollingElement.scrollTop === 0), 'Space does not scroll the page');

	await page.keyboard.press('Tab');
	await frames(page, 2);
	let g = await qa(page);
	check(g.cat !== f.cat, 'Tab switches cat', { from: f.cat, to: g.cat });
	check(await page.evaluate(() => document.activeElement && document.activeElement.id === 'canvas'), 'Tab keeps focus on the game canvas');
	await page.screenshot({ path: path.join(OUT, 'desktop-2-tuxedo.png') });
	await page.keyboard.press('Tab');
	await frames(page, 2);

	const yaw0 = (await qa(page)).cam_yaw;
	await page.mouse.move(700, 420);
	await page.mouse.down({ button: 'right' });
	for (let i = 1; i <= 10; i++) await page.mouse.move(700 - i * 15, 420, { steps: 1 });
	await page.mouse.up({ button: 'right' });
	await frames(page, 2);
	let h = await qa(page);
	check(Math.abs(angDiff(h.cam_yaw, yaw0)) > 0.5 && !h.captured, 'right-button drag turns the camera without pointer capture', { dyaw: +angDiff(h.cam_yaw, yaw0).toFixed(2) });

	// Letter: drive there with the keyboard, then E.
	await kbWalkTo(page, -2.2 + 0.35, -0.4 + 0.2, 0.15);
	s = await qa(page);
	check(/편지 물기/.test(s.prompt), 'context prompt offers to take the letter', s.prompt);
	await page.keyboard.press('KeyE');
	s = await waitQA(page, (q) => q.has_letter, 20000);
	check(s.has_letter && s.carrying_visible, 'E picks up the letter (carried in the mouth)');

	// Click on the game: request pointer lock from the click. Then Esc must pause and never recapture.
	await page.mouse.click(640, 380);
	s = await waitQA(page, (q) => q.captured, 15000);
	const lockWorked = !!(s && s.captured);
	console.log('        pointer lock granted in this headless browser:', lockWorked);
	if (lockWorked) {
		const y0 = s.cam_yaw;
		await page.evaluate(() => {
			window.__mv = [];
			document.addEventListener('mousemove', (e) => window.__mv.push(e.movementX), true);
		});
		await page.mouse.move(600, 380);
		await page.mouse.move(500, 380);
		await frames(page, 2);
		s = await qa(page);
		const mv = await page.evaluate(() => window.__mv);
		const net = mv.reduce((a, b) => a + b, 0);
		if (net !== 0) {
			check(Math.abs(angDiff(s.cam_yaw, y0)) > 0.05, 'captured mouse turns the camera');
		} else {
			// Headless Chromium emits paired +N/-N movementX events under pointer lock (net 0),
			// so captured-mouse look cannot be exercised here; real mice report one-way movementX.
			console.log('        (not verifiable here: synthetic pointer-lock mousemove nets movementX=0)');
		}
	}
	await page.keyboard.press('Escape');
	s = await waitQA(page, (q) => q.state === 'paused', 20000);
	check(s.state === 'paused' && !s.captured, 'Esc pauses (and releases the pointer)');
	await page.screenshot({ path: path.join(OUT, 'desktop-3-paused.png') });
	const p0 = s;
	await page.keyboard.down('KeyW');
	await frames(page, 4);
	s = await qa(page);
	check(flat(p0, s) < 0.001, 'no movement while paused');
	await page.keyboard.up('KeyW');
	await page.keyboard.press('KeyE');
	await frames(page, 2);
	s = await qa(page);
	check(s.has_letter && !s.delivered, 'interaction does nothing while paused');
	await sleep(400);
	check(await clickHud(page, s, '계속하기'), 'Resume button found');
	s = await waitQA(page, (q) => q.state === 'playing', 20000);
	await frames(page, 3);
	s = await qa(page);
	check(s.state === 'playing' && !s.captured, 'Resume resumes without grabbing the pointer again');

	const yaw1 = s.cam_yaw;
	await clickHud(page, s, '일시정지');
	s = await waitQA(page, (q) => q.state === 'paused', 20000);
	check(s.state === 'paused' && !s.captured && s.cam_yaw === yaw1, 'HUD Pause click pauses with no camera turn or capture');
	await sleep(400);
	await clickHud(page, s, '계속하기');
	await waitQA(page, (q) => q.state === 'playing', 20000);

	// Focus loss while walking: pause and release; coming back must not keep walking.
	await page.keyboard.down('KeyW');
	await steps(page, 12);
	await page.evaluate(() => window.dispatchEvent(new Event('blur')));
	s = await waitQA(page, (q) => q.state === 'paused', 20000);
	check(s.state === 'paused', 'window blur pauses the game');
	await sleep(400);
	await clickHud(page, s, '계속하기');
	await waitQA(page, (q) => q.state === 'playing', 20000);
	await steps(page, 6);
	const r1 = await qa(page);
	await steps(page, 30);
	const r2 = await qa(page);
	check(flat(r1, r2) < 0.01, 'after focus returns the cat is not still walking (key released while away)');
	await page.keyboard.up('KeyW');

	// Window resize keeps the UI anchored.
	await page.setViewportSize({ width: 1024, height: 640 });
	await frames(page, 3);
	s = await qa(page);
	const cr = await canvasRect(page);
	let inside = true;
	for (const [k, r] of Object.entries(s.hud_buttons)) {
		if (r[0] < 0 || r[1] < 0 || r[0] + r[2] > s.vp[0] + 0.5 || r[1] + r[3] > s.vp[1] + 0.5) inside = false;
	}
	check(inside && Math.round(cr.width) === 1024, 'after resize the canvas fills the window and HUD stays on screen', { vp: s.vp });
	await page.setViewportSize({ width: 1280, height: 800 });
	await frames(page, 2);
	check(t.errors.length === 0, 'desktop: no page/console errors', t.errors.slice(0, 5));
	check(t.bad.length === 0, 'desktop: no failed requests / 404s', t.bad.slice(0, 5));
	s = await qa(page);
	console.log('        desktop fps (SwiftShader software WebGL, 1280x800 CSS @0.5x):', s.fps, 'draw calls:', s.draw_calls);
	await ctx.close();
}

// ------------------------------------------------------------ full route (touch stick)
// Drives the whole delivery with the on-screen analog stick + JUMP/LETTER/CAT buttons.
// The stick is analog, so the cat can be placed precisely even when software WebGL
// renders only a few frames per second (one keyboard tap moves ~8 physics steps here).
async function route(browser) {
	console.log('-- full delivery route in the browser (mobile landscape, touch stick + buttons)');
	// Same 844x390 CSS layout, rendered at 0.25x pixel ratio: software WebGL then runs ~15 fps
	// instead of ~4, which keeps input latency (2-3 frames) small enough to steer.
	const ctx = await browser.newContext({ viewport: { width: 844, height: 390 }, deviceScaleFactor: 0.25, isMobile: true, hasTouch: true });
	const page = await ctx.newPage();
	const t = track(page);
	const cdp = await ctx.newCDPSession(page);
	const send = (type, pts) => cdp.send('Input.dispatchTouchEvent', { type, touchPoints: pts });
	let s = await startGame(page, 'route');
	const L = s.touch_layout;
	const r = await canvasRect(page);
	const k = r.width / s.vp[0];
	const at = (id) => ({ x: r.x + L[id][0] * k, y: r.y + L[id][1] * k });
	const home = at('stick_home');
	const R = L.stick_home[2] * k;
	const jumpBtn = at('jump');
	let stickDown = false;
	let jumpDown = false;
	let stickPos = home;
	const points = () => {
		const p = [];
		if (stickDown) p.push({ x: stickPos.x, y: stickPos.y, id: 0 });
		if (jumpDown) p.push({ x: jumpBtn.x, y: jumpBtn.y, id: 1 });
		return p;
	};
	const local = (dx, dz, yaw) => [dx * Math.cos(yaw) - dz * Math.sin(yaw), dx * Math.sin(yaw) + dz * Math.cos(yaw)];
	async function stick(dx, dz, mag, yaw) {
		if (mag <= 0) {
			// CDP touchEnd ends the points that are listed.
			if (stickDown) { stickDown = false; await send('touchEnd', [{ x: stickPos.x, y: stickPos.y, id: 0 }]); }
			return;
		}
		const [lx, lz] = local(dx, dz, yaw);
		const n = Math.hypot(lx, lz) || 1;
		if (!stickDown) { stickPos = { ...home }; stickDown = true; await send('touchStart', points()); }
		stickPos = { x: home.x + (lx / n) * mag * R, y: home.y + (lz / n) * mag * R };
		await send('touchMove', points());
	}
	async function tap(id) {
		const b = at(id);
		await send('touchStart', points().concat([{ x: b.x, y: b.y, id: 5 }]));
		await send('touchEnd', [{ x: b.x, y: b.y, id: 5 }]);
		await frames(page, 2);
	}
	// hug > 0 adds a push toward +X (the building wall) so narrow ledges are walked like a player would.
	// Speed is proportional to the remaining distance, so slow frames cannot overshoot much.
	async function walkTo(tx, tz, tol, hug = 0, timeout = 240000) {
		const t0 = Date.now();
		let q = await qa(page);
		while (Date.now() - t0 < timeout) {
			q = await qa(page);
			const dx = tx - q.pos[0];
			const dz = tz - q.pos[2];
			const d = hug ? Math.abs(dz) : Math.hypot(dx, dz);
			if (d < tol) break;
			const n = Math.hypot(dx, dz) || 1;
			await stick(dx / n + hug, dz / n, Math.min(1, Math.max(0.16, d * 0.8)), q.cam_yaw);
			await frames(page, 1);
		}
		await stick(0, 0, 0, 0);
		q = await waitQA(page, (x) => hspeed(x) < 0.03, 30000, 10);
		return hug ? Math.abs(tz - q.pos[2]) : Math.hypot(tx - q.pos[0], tz - q.pos[2]);
	}
	// Full charge, then aim: stick magnitude sets the leap speed (2.2 m/s at full stick) so that
	// speed x flight time = gap. Held unchanged in the air (no late corrections at low fps).
	async function jumpTo(tx, ty, tz, expect, label, hug = 0) {
		let q = await qa(page);
		const j0 = q.jumps;
		jumpDown = true;
		await send('touchStart', points());
		await waitQA(page, (x) => x.charging && x.charge >= 0.999, 30000, 5);
		q = await qa(page);
		const from = q.pos.map((v) => +v.toFixed(2));
		let peak = q.pos[1];
		const v0 = 6.6;
		const g = 15;
		const dh = ty - q.pos[1];
		const T = (v0 + Math.sqrt(Math.max(0, v0 * v0 - 2 * g * dh))) / g;
		const dx = tx - q.pos[0];
		const dz = tz - q.pos[2];
		const D = Math.hypot(dx, dz) || 1;
		let vx = (dx / D) * Math.min(2.2, D / T);
		let vz = (dz / D) * Math.min(2.2, D / T);
		if (hug) {
			vx = hug;
			vz = Math.sign(dz) * Math.min(2.1, Math.abs(dz) / T);
		}
		await stick(vx, vz, Math.min(1, Math.hypot(vx, vz) / 2.2), q.cam_yaw);
		await frames(page, 1);
		jumpDown = false;
		await send('touchEnd', [{ x: jumpBtn.x, y: jumpBtn.y, id: 1 }]);
		let left = false;
		let lifted = false;
		const t0 = Date.now();
		while (Date.now() - t0 < 60000) {
			await frames(page, 1);
			q = await qa(page);
			if (!q.on_floor) left = true;
			peak = Math.max(peak, q.pos[1]);
			if (left && q.on_floor) break;
			// Let go early enough that input latency (~0.2 s) plus air drag (4.5 m/s^2) ends on target.
			const rem = hug ? Math.abs(tz - q.pos[2]) : Math.hypot(tx - q.pos[0], tz - q.pos[2]);
			const v = hspeed(q);
			if (left && !lifted && rem <= v * 0.2 + (v * v) / 9) {
				lifted = true;
				if (hug) await stick(hug, 0, Math.min(1, hug / 2.2), q.cam_yaw);
				else await stick(0, 0, 0, 0);
			}
		}
		await stick(0, 0, 0, 0);
		q = await waitQA(page, (x) => x.on_floor && hspeed(x) < 0.05, 30000, 10);
		return check(left && q.jumps === j0 + 1 && q.platform === expect,
			`route: leap to ${label} lands on route platform #${expect}`,
			{ platform: q.platform, from, peak: +peak.toFixed(2), to: q.pos.map((v) => +v.toFixed(2)) });
	}

	await walkTo(-1.95, -0.25, 0.2);
	s = await qa(page);
	check(/편지 물기/.test(s.prompt), 'route: LETTER prompt next to the letter', s.prompt);
	await tap('letter');
	s = await waitQA(page, (q) => q.has_letter, 20000);
	check(s.has_letter && s.carrying_visible, 'route: LETTER button picks up the letter');
	check(await walkTo(1.75, -2.2, 0.12) < 0.3, 'route: walked to the low box');
	await jumpTo(1.75, 0.5, -3.2, 0, 'low box');
	await walkTo(1.9, -3.3, 0.1);
	await jumpTo(2.55, 1.3, -3.9, 1, 'wall');
	await walkTo(2.55, -8.0, 0.12);
	s = await qa(page);
	check(s.platform === 1, 'route: walked along the wall top');
	await jumpTo(3.33, 2.1, -8.0, 2, 'AC unit');
	await walkTo(3.4, -8.15, 0.1, 0.6);
	await jumpTo(3.43, 2.9, -9.5, 3, 'narrow ledge', 0.4);
	await walkTo(3.43, -12.45, 0.15, 0.6);
	s = await qa(page);
	check(s.platform === 3, 'route: walked the narrow ledge without falling');
	const cat0 = s.cat;
	await tap('cat');
	s = await waitQA(page, (q) => q.cat !== cat0, 20000);
	check(s.cat !== cat0 && s.has_letter && s.platform === 3, 'route: CAT switch on the ledge keeps letter and position');
	await jumpTo(3.2, 3.6, -13.75, 4, 'sign', 0.4);
	await jumpTo(3.3, 4.3, -15.0, 5, '302 sill', 0.4);
	await walkTo(3.3, -15.45, 0.2, 0.6);
	s = await qa(page);
	check(/편지 전달/.test(s.prompt), 'route: prompt offers delivery at 302', s.prompt);
	await tap('letter');
	s = await waitQA(page, (q) => q.delivered && q.window_light > 2.0, 60000);
	check(s.delivered && !s.has_letter && s.window_light > 2.0, 'route: letter delivered, 302 window lit');
	await page.screenshot({ path: path.join(OUT, 'route-1-delivered.png') });
	s = await waitQA(page, (q) => q.state === 'complete', 60000);
	check(s.state === 'complete', 'route: completion screen shown');
	await page.screenshot({ path: path.join(OUT, 'route-2-complete.png') });
	check(t.errors.length === 0 && t.bad.length === 0, 'route: no errors / failed requests', t.errors.concat(t.bad).slice(0, 5));
	await ctx.close();
}

// ------------------------------------------------------------ mobile landscape (touch emulation)
async function mobile(browser) {
	console.log('-- mobile landscape 844x390 (Chromium mobile emulation + CDP touch events)');
	const ctx = await browser.newContext({ viewport: { width: 844, height: 390 }, deviceScaleFactor: 1, isMobile: true, hasTouch: true });
	const page = await ctx.newPage();
	const t = track(page);
	const cdp = await ctx.newCDPSession(page);
	const touch = async (type, pts) => cdp.send('Input.dispatchTouchEvent', { type, touchPoints: pts.map((p) => ({ x: p.x, y: p.y, id: p.id })) });

	let s = await startGame(page, 'mobile');
	check(s.touch, 'touch controls shown on a coarse-pointer device');
	await frames(page, 2);
	await page.screenshot({ path: path.join(OUT, 'mobile-1-play.png') });
	s = await qa(page);
	const k = (await canvasRect(page)).width / s.vp[0];
	const L = s.touch_layout;
	const sizes = {};
	let minPx = 1e9;
	for (const id of ['jump', 'letter', 'cat', 'route', 'run']) {
		sizes[id] = Math.round(L[id][2] * 2 * k);
		minPx = Math.min(minPx, sizes[id]);
	}
	for (const [label, r] of Object.entries(s.hud_buttons)) {
		sizes[label] = [Math.round(r[2] * k), Math.round(r[3] * k)];
		minPx = Math.min(minPx, r[3] * k);
	}
	check(minPx >= 44, 'every touch target is >= 44 CSS px on an 844x390 screen', sizes);
	const circles = ['jump', 'letter', 'cat', 'route', 'run', 'stick_home'].map((id) => [id, L[id]]);
	let overlap = [];
	for (let i = 0; i < circles.length; i++) {
		for (let j = i + 1; j < circles.length; j++) {
			const [a, b] = [circles[i][1], circles[j][1]];
			if (Math.hypot(a[0] - b[0], a[1] - b[1]) < a[2] + b[2]) overlap.push(circles[i][0] + '/' + circles[j][0]);
		}
		const c = circles[i][1];
		for (const r of Object.values(s.hud_buttons)) {
			if (c[0] + c[2] > r[0] && c[0] - c[2] < r[0] + r[2] && c[1] + c[2] > r[1] && c[1] - c[2] < r[1] + r[3]) overlap.push(circles[i][0] + '/hud');
		}
	}
	check(overlap.length === 0, 'touch controls do not overlap each other or the Pause/Home buttons', overlap);

	const css = async (vx, vy) => toCss(page, s, vx, vy);
	const stick = await css(L.stick_home[0], L.stick_home[1]);
	const jump = await css(L.jump[0], L.jump[1]);
	const cat = await css(L.cat[0], L.cat[1]);
	const camSpot = { x: 844 * 0.7, y: 390 * 0.3 };

	// Finger 0 on the stick, finger 1 charges JUMP at the same time.
	const a = await qa(page);
	await touch('touchStart', [{ ...stick, id: 0 }]);
	for (let i = 1; i <= 6; i++) await touch('touchMove', [{ x: stick.x, y: stick.y - i * 10, id: 0 }]);
	await steps(page, 24);
	let b = await qa(page);
	check(b.stick[1] < -0.4 && flat(a, b) > 0.2, 'stick finger moves the cat', { stick: b.stick, moved: +flat(a, b).toFixed(2) });
	const j0 = b.jumps;
	const yaw0 = b.cam_yaw;
	await touch('touchStart', [{ x: stick.x, y: stick.y - 60, id: 0 }, { ...jump, id: 1 }]);
	await waitQA(page, (q) => q.charging, 20000, 5);
	let c = await qa(page);
	check(c.charging && c.jump_held && c.stick[1] < -0.4, 'stick + JUMP held together (moving while charging)');
	await page.screenshot({ path: path.join(OUT, 'mobile-2-multitouch.png') });
	for (let i = 1; i <= 6; i++) {
		await touch('touchMove', [{ x: stick.x, y: stick.y - 60, id: 0 }, { x: jump.x + (camSpot.x - jump.x) * i / 6, y: jump.y + (camSpot.y - jump.y) * i / 6, id: 1 }]);
	}
	await frames(page, 2);
	let d = await qa(page);
	check(d.cam_yaw === yaw0, 'JUMP finger sliding away does not turn the camera');
	await touch('touchEnd', [{ ...camSpot, id: 1 }]);
	let e = await waitQA(page, (q) => q.jumps === j0 + 1, 20000, 5);
	check(e.jumps === j0 + 1 && !e.jump_held, 'lifting the JUMP finger (outside the button) leaps once');
	await touch('touchEnd', []);
	await waitQA(page, (q) => q.on_floor, 30000);
	await steps(page, 24);
	let f = await qa(page);
	check(f.stick[0] === 0 && f.stick[1] === 0 && hspeed(f) < 0.05, 'lifting the stick finger stops the cat');

	await touch('touchStart', [{ ...camSpot, id: 2 }]);
	for (let i = 1; i <= 8; i++) await touch('touchMove', [{ x: camSpot.x - i * 15, y: camSpot.y, id: 2 }]);
	await touch('touchEnd', []);
	await frames(page, 2);
	let g = await qa(page);
	check(Math.abs(angDiff(g.cam_yaw, f.cam_yaw)) > 0.3, 'dragging the empty right side turns the camera', { dyaw: +angDiff(g.cam_yaw, f.cam_yaw).toFixed(2) });

	await touch('touchStart', [{ ...cat, id: 3 }]);
	await touch('touchEnd', []);
	let h = await waitQA(page, (q) => q.cat !== g.cat, 20000);
	check(h.cat !== g.cat, 'CAT button switches cats', h.cat);

	// touchcancel while charging: no jump.
	const j1 = h.jumps;
	await touch('touchStart', [{ ...jump, id: 4 }]);
	await waitQA(page, (q) => q.charging, 20000, 5);
	await touch('touchCancel', []);
	await steps(page, 30);
	let i1 = await qa(page);
	check(i1.jumps === j1 && !i1.charging && !i1.jump_held, 'touchcancel drops the charge without jumping');

	// Rotate to portrait and back: rotate notice + pause, touches cleared, resume by touch.
	await touch('touchStart', [{ ...stick, id: 5 }]);
	await touch('touchMove', [{ x: stick.x + 40, y: stick.y, id: 5 }]);
	await page.setViewportSize({ width: 390, height: 844 });
	let p = await waitQA(page, (q) => q.portrait_blocked, 30000);
	check(p.portrait_blocked && p.state === 'paused' && p.stick[0] === 0, 'portrait: rotate notice, game paused, stick released');
	await page.screenshot({ path: path.join(OUT, 'mobile-3-portrait.png') });
	await touch('touchEnd', []);
	await page.setViewportSize({ width: 844, height: 390 });
	p = await waitQA(page, (q) => !q.portrait_blocked, 30000);
	check(!p.portrait_blocked && p.state === 'paused', 'back to landscape: still paused until Resume');
	await sleep(400);
	const res = await hudCenter(page, p, '계속하기');
	await touch('touchStart', [{ ...res, id: 6 }]);
	await touch('touchEnd', []);
	p = await waitQA(page, (q) => q.state === 'playing', 20000);
	check(p.state === 'playing', 'touching Resume resumes');

	// HUD Pause by touch, then focus loss while holding the stick.
	const pz = await hudCenter(page, p, '일시정지');
	await touch('touchStart', [{ ...pz, id: 7 }]);
	await touch('touchEnd', []);
	p = await waitQA(page, (q) => q.state === 'paused', 20000);
	check(p.state === 'paused', 'touching Pause pauses');
	await sleep(400);
	await touch('touchStart', [{ ...(await hudCenter(page, p, '계속하기')), id: 8 }]);
	await touch('touchEnd', []);
	await waitQA(page, (q) => q.state === 'playing', 20000);
	await touch('touchStart', [{ ...stick, id: 9 }]);
	await touch('touchMove', [{ x: stick.x, y: stick.y - 60, id: 9 }]);
	await steps(page, 6);
	await page.evaluate(() => window.dispatchEvent(new Event('blur')));
	p = await waitQA(page, (q) => q.state === 'paused', 20000);
	check(p.state === 'paused' && p.stick[1] === 0, 'focus loss pauses and releases the stick');
	await sleep(400);
	await touch('touchStart', [{ ...(await hudCenter(page, p, '계속하기')), id: 10 }]);
	await touch('touchEnd', []);
	await waitQA(page, (q) => q.state === 'playing', 20000);
	await steps(page, 6);
	const m1 = await qa(page);
	await steps(page, 30);
	const m2 = await qa(page);
	check(flat(m1, m2) < 0.01, 'after resuming nothing keeps moving');
	check(t.errors.length === 0, 'mobile: no page/console errors', t.errors.slice(0, 5));
	check(t.bad.length === 0, 'mobile: no failed requests / 404s', t.bad.slice(0, 5));
	console.log('        mobile-emulation fps (SwiftShader software WebGL, 844x390 @1x):', m2.fps, 'draw calls:', m2.draw_calls);
	await ctx.close();
}

// ------------------------------------------------------------ failure screens
async function failures(browser) {
	console.log('-- error screens');
	const ctx = await browser.newContext(DESKTOP);
	const page = await ctx.newPage();
	const file = 'file://' + path.resolve(__dirname, '..', 'builds', 'web', 'index.html');
	await page.goto(file);
	await sleep(300);
	const txt = await page.locator('#error-text').textContent();
	check(await page.locator('#screen-error').isVisible() && /file:\/\//.test(txt), 'file:// shows a readable error instead of a black screen');
	if (process.env.BROKEN_BASE) {
		await page.goto(process.env.BROKEN_BASE);
		await page.click('#btn-start');
		await page.locator('#screen-error').waitFor({ state: 'visible', timeout: 30000 }).catch(() => {});
		const shown = await page.locator('#screen-error').isVisible();
		check(shown, 'missing index.pck shows the error screen with a reload button',
			shown ? await page.locator('#error-text').textContent() : null);
		await page.screenshot({ path: path.join(OUT, 'error-missing-pck.png') });
	}
	await ctx.close();
}

(async () => {
	const browser = await chromium.launch(LAUNCH);
	try {
		if (!ONLY || ONLY.includes('desktop')) await desktop(browser);
		if (!ONLY || ONLY.includes('route')) await route(browser);
		if (!ONLY || ONLY.includes('mobile')) await mobile(browser);
		if (!ONLY || ONLY.includes('errors')) await failures(browser);
	} catch (err) {
		check(false, 'browser test crashed: ' + (err && err.stack ? err.stack.split('\n').slice(0, 3).join(' | ') : err));
	} finally {
		await browser.close();
	}
	fs.writeFileSync(path.join(OUT, 'browser-results.json'), JSON.stringify(summary, null, 1));
	console.log(`== browser: ${summary.length} checks, ${failed} failed ==`);
	process.exit(failed ? 1 : 0);
})();
