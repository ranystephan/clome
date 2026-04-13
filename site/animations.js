(function () {
  "use strict";
  var rm = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var mob = window.innerWidth <= 768;
  var INK = "rgba(14,16,20,";

  /* ── Reveals ───────────────────────────────────────────────── */
  function initReveals() {
    var t = document.querySelectorAll("[data-reveal],[data-stagger]");
    if (!t.length) return;
    if (rm) { t.forEach(function(e){e.classList.add("vis")}); return; }
    var o = new IntersectionObserver(function(es,ob){es.forEach(function(e){if(e.isIntersecting){e.target.classList.add("vis");ob.unobserve(e.target)}})},{threshold:0.06,rootMargin:"0px 0px -6% 0px"});
    t.forEach(function(e){o.observe(e)});
  }

  /* ── Anchors ───────────────────────────────────────────────── */
  function initAnchors() {
    document.querySelectorAll('a[href^="#"]').forEach(function(l){l.addEventListener("click",function(e){var h=l.getAttribute("href");if(!h||h==="#")return;var t=document.querySelector(h);if(!t)return;e.preventDefault();var b=document.querySelector(".top-bar");var off=b?b.getBoundingClientRect().height+16:80;window.scrollTo({top:t.getBoundingClientRect().top+window.scrollY-off,behavior:rm?"auto":"smooth"})})});
  }

  /* ── Grain ─────────────────────────────────────────────────── */
  function initGrain() {
    var c=document.getElementById("grain");if(!c||rm||mob)return;var x=c.getContext("2d"),w=0,h=0,f=0;
    function rs(){w=c.width=window.innerWidth;h=c.height=window.innerHeight}rs();window.addEventListener("resize",rs);
    (function d(){if(f++%3!==0){requestAnimationFrame(d);return}var m=x.createImageData(w,h),a=m.data;for(var i=0;i<a.length;i+=4){var v=(Math.random()*255)|0;a[i]=v;a[i+1]=v;a[i+2]=v;a[i+3]=255}x.putImageData(m,0,0);requestAnimationFrame(d)})();
  }

  /* ── Copy ───────────────────────────────────────────────────── */
  function initCopy() {
    document.querySelectorAll("[data-copy]").forEach(function(b){b.addEventListener("click",function(){navigator.clipboard.writeText(b.getAttribute("data-copy")).then(function(){b.classList.add("copied");b.querySelector(".icon-copy").style.display="none";b.querySelector(".icon-check").style.display="";setTimeout(function(){b.classList.remove("copied");b.querySelector(".icon-copy").style.display="";b.querySelector(".icon-check").style.display="none"},2000)})})});
  }

  /* ── Shared curve math ─────────────────────────────────────── */

  function qb(t, a, b, c) { var m = 1 - t; return m * m * a + 2 * m * t * b + t * t * c; }

  // Logo front curve Q bezier chain
  var fSegs = [
    [224,608, 265.661,608, 322.081,507.074],
    [322.081,507.074, 362.298,435.131, 390.383,405.911],
    [390.383,405.911, 442.2,352, 512,352],
    [512,352, 581.8,352, 633.617,405.911],
    [633.617,405.911, 661.702,435.131, 701.919,507.074],
    [701.919,507.074, 758.339,608, 800,608]
  ];
  // Logo back curve
  var bSegs = [
    [224,352, 278.573,352, 320.759,398.584],
    [320.759,398.584, 342.937,423.074, 377.944,485.697],
    [377.944,485.697, 414.145,550.455, 436.525,573.74],
    [436.525,573.74, 469.455,608, 512,608],
    [512,608, 554.545,608, 587.474,573.74],
    [587.474,573.74, 609.855,550.454, 646.056,485.697],
    [646.056,485.697, 681.063,423.074, 703.241,398.584],
    [703.241,398.584, 745.427,352, 800,352]
  ];

  var N = 120;

  function precompute(segs) {
    var raw = [], result = [], ri = 0;
    for (var s = 0; s < segs.length; s++) {
      var sg = segs[s], n = 40;
      for (var i = (s === 0 ? 0 : 1); i <= n; i++) {
        var t = i / n;
        raw.push({ x: qb(t, sg[0], sg[2], sg[4]), y: qb(t, sg[1], sg[3], sg[5]) });
      }
    }
    for (var j = 0; j <= N; j++) {
      var tx = 224 + 576 * j / N;
      while (ri < raw.length - 2 && raw[ri + 1].x < tx) ri++;
      var a = raw[ri], b = raw[Math.min(ri + 1, raw.length - 1)];
      var f = b.x > a.x ? Math.max(0, Math.min(1, (tx - a.x) / (b.x - a.x))) : 0;
      result.push((480 - (a.y + (b.y - a.y) * f)) / 128);
    }
    return result;
  }

  var logoF = precompute(fSegs);
  var logoB = precompute(bSegs);

  // Draw a displacement array as a thick curve
  function strokeCurve(ctx, disp, amp, cx, cy, cw, ch, padX, color, sw) {
    ctx.beginPath();
    for (var i = 0; i <= disp.length - 1; i++) {
      var x = padX + (i / (disp.length - 1)) * (cw - 2 * padX);
      var y = cy - amp * ch * disp[i];
      if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
    }
    ctx.strokeStyle = color; ctx.lineWidth = sw;
    ctx.lineCap = "round"; ctx.lineJoin = "round"; ctx.stroke();
  }

  /* ── Hero logo ─────────────────────────────────────────────── */

  function initHeroLogo() {
    var canvas = document.getElementById("hero-logo");
    if (!canvas) return;
    var ctx = canvas.getContext("2d");
    var dpr = Math.min(window.devicePixelRatio || 1, 2);
    var cw = 0, ch = 0, startT = performance.now(), time = 0;

    function resize() {
      var r = canvas.parentElement.getBoundingClientRect();
      cw = r.width; ch = r.height;
      canvas.width = cw * dpr; canvas.height = ch * dpr;
      canvas.style.width = cw + "px"; canvas.style.height = ch + "px";
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    }
    resize(); window.addEventListener("resize", resize);

    var PAD = 0.13, CY = 0.5, AMP = 0.28;

    function xp(nx) { return PAD * cw + nx * (cw - 2 * PAD * cw); }
    function yp(d) { return ch * (CY - AMP * d); }

    function drawGrid() {
      ctx.save(); ctx.setLineDash([4, 5]); ctx.strokeStyle = INK + "0.07)"; ctx.lineWidth = 0.5;
      ctx.beginPath(); ctx.moveTo(xp(-0.04), yp(0)); ctx.lineTo(xp(1.04), yp(0)); ctx.stroke();
      ctx.strokeStyle = INK + "0.04)";
      ctx.beginPath(); ctx.moveTo(xp(-0.03), yp(1)); ctx.lineTo(xp(1.03), yp(1)); ctx.stroke();
      ctx.beginPath(); ctx.moveTo(xp(-0.03), yp(-1)); ctx.lineTo(xp(1.03), yp(-1)); ctx.stroke();
      ctx.strokeStyle = INK + "0.06)";
      [0, 0.5, 1].forEach(function(v) { ctx.beginPath(); ctx.moveTo(xp(v), yp(1.15)); ctx.lineTo(xp(v), yp(-1.15)); ctx.stroke(); });
      ctx.setLineDash([]);
      ctx.strokeStyle = INK + "0.08)"; ctx.lineWidth = 0.6;
      for (var i = 0; i <= 10; i++) { var tx = xp(i / 10); ctx.beginPath(); ctx.moveTo(tx, yp(0) - 3); ctx.lineTo(tx, yp(0) + 3); ctx.stroke(); }
      ctx.beginPath(); ctx.arc(xp(0.5), yp(0), 3, 0, Math.PI * 2); ctx.strokeStyle = INK + "0.12)"; ctx.lineWidth = 1; ctx.stroke();
      ctx.restore();
    }

    function drawTracer(elapsed) {
      var t = (Math.sin(elapsed * 0.7) + 1) / 2;
      var idx = Math.round(t * N);
      var x = xp(idx / N), y = yp(logoF[idx]);
      var i0 = Math.max(0, idx - 3), i1 = Math.min(N, idx + 3);
      var dx = xp(i1 / N) - xp(i0 / N), dy = yp(logoF[i1]) - yp(logoF[i0]);
      var len = Math.sqrt(dx * dx + dy * dy);
      if (len > 1) {
        var nx = dx / len * 20, ny = dy / len * 20;
        ctx.beginPath(); ctx.moveTo(x - nx, y - ny); ctx.lineTo(x + nx, y + ny);
        ctx.strokeStyle = INK + "0.1)"; ctx.lineWidth = 0.8; ctx.setLineDash([4, 4]); ctx.stroke(); ctx.setLineDash([]);
      }
      ctx.beginPath(); ctx.arc(x, y, 10, 0, Math.PI * 2); ctx.fillStyle = INK + "0.03)"; ctx.fill();
      ctx.beginPath(); ctx.arc(x, y, 3.5, 0, Math.PI * 2); ctx.fillStyle = INK + "0.5)"; ctx.fill();
    }

    function frame() {
      ctx.clearRect(0, 0, cw, ch);
      var elapsed = (performance.now() - startT) / 1000;
      var prog = rm ? 1 : Math.min(elapsed / 1.8, 1);
      prog = 1 - Math.pow(1 - prog, 3);
      var SW = Math.min(cw, ch) * 0.05;

      // Subtle breathing
      var br = rm ? 0 : Math.sin(elapsed * 0.4) * 0.008;
      var ampNow = AMP + br;

      var ga = Math.max(0, Math.min((elapsed - 1) / 1, 1));
      if (ga > 0.01) { ctx.globalAlpha = ga; drawGrid(); ctx.globalAlpha = 1; }

      var vc = Math.ceil(prog * (N + 1));
      var fv = logoF.slice(0, vc), bv = logoB.slice(0, vc);

      strokeCurve(ctx, bv, ampNow, 0, ch * CY, cw, ch, PAD * cw, INK + "0.18)", SW);
      strokeCurve(ctx, fv, ampNow, 0, ch * CY, cw, ch, PAD * cw, INK + "0.78)", SW);

      if (prog >= 1 && !rm) drawTracer(elapsed);
      if (!rm) requestAnimationFrame(frame);
    }
    requestAnimationFrame(frame);
  }

  /* ── Section motifs ────────────────────────────────────────── */

  function initMotifs() {
    var canvases = document.querySelectorAll(".section-motif");
    if (!canvases.length) return;

    var dpr = Math.min(window.devicePixelRatio || 1, 2);

    canvases.forEach(function(canvas) {
      var type = canvas.getAttribute("data-motif");
      var rect = canvas.getBoundingClientRect();
      var w = Math.round(rect.width) || 100, h = Math.round(rect.height) || 48;
      canvas.width = w * dpr; canvas.height = h * dpr;
      canvas.style.width = w + "px"; canvas.style.height = h + "px";
      var ctx = canvas.getContext("2d");
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

      var drawn = false;
      var obs = new IntersectionObserver(function(entries) {
        if (entries[0].isIntersecting && !drawn) {
          drawn = true;
          if (type === "progress") { drawProgress(ctx, w, h); }
          else { setTimeout(function() { drawMotif(ctx, w, h, type); }, 400); }
          obs.disconnect();
        }
      }, { threshold: 0.1 });
      obs.observe(canvas);
    });

    // §1 Abstract — single flowing curve (one half of logo)
    // §2 Components — three small intertwined pairs
    // §3 Stack — parallel layered curves
    // §4 Status — curve that draws itself
    // §5 Source — terminal angle bracket

    // Scale factor relative to desktop (100x48) for proportional rendering
    function drawMotif(ctx, w, h, type) {
      ctx.lineCap = "round"; ctx.lineJoin = "round";
      var s = w / 100; // scale factor

      if (type === "single") {
        var pts = [];
        for (var i = 0; i <= 60; i++) {
          var t = i / 60;
          var idx = Math.round(t * N);
          pts.push({ x: 8 * s + t * (w - 16 * s), y: h / 2 - logoF[idx] * h * 0.36 });
        }
        animateStroke(ctx, pts, INK + "0.6)", 2.5 * s, 800);
      }

      else if (type === "trio") {
        var ox = 6 * s, cy = h / 2;
        var branches = [
          { endY: cy - h * 0.38, cp1y: cy - h * 0.05, cp2y: cy - h * 0.32, alpha: 0.55, delay: 0 },
          { endY: cy,            cp1y: cy + h * 0.08,  cp2y: cy - h * 0.04, alpha: 0.35, delay: 120 },
          { endY: cy + h * 0.38, cp1y: cy + h * 0.15,  cp2y: cy + h * 0.30, alpha: 0.2,  delay: 240 },
        ];
        branches.forEach(function(br) {
          setTimeout(function() {
            var pts = [];
            for (var i = 0; i <= 40; i++) {
              var t = i / 40;
              var m = 1 - t;
              var x = ox + t * (w - 14 * s);
              var y = m*m*m*cy + 3*m*m*t*br.cp1y + 3*m*t*t*br.cp2y + t*t*t*br.endY;
              pts.push({ x: x, y: y });
            }
            animateStroke(ctx, pts, INK + br.alpha + ")", 1.8 * s, 600);
          }, br.delay);
        });
      }

      else if (type === "layers") {
        for (var l = 0; l < 5; l++) {
          (function(l) {
            setTimeout(function() {
              var ly = 8 * s + l * (h - 16 * s) / 4;
              var pts = [];
              for (var i = 0; i <= 40; i++) {
                var t = i / 40;
                pts.push({ x: 8 * s + t * (w - 16 * s), y: ly + Math.sin(t * Math.PI * 2 + l * 0.5) * 3 * s });
              }
              var alpha = 0.15 + (l / 4) * 0.4;
              animateStroke(ctx, pts, INK + alpha + ")", (1.2 + l * 0.3) * s, 500);
            }, l * 100);
          })(l);
        }
      }

      else if (type === "terminal") {
        setTimeout(function() {
          var pts1 = [
            { x: w * 0.15, y: h * 0.21 }, { x: w * 0.45, y: h / 2 }, { x: w * 0.15, y: h * 0.79 }
          ];
          animateStroke(ctx, pts1, INK + "0.55)", 2 * s, 500);

          setTimeout(function() {
            var pts2 = [{ x: w * 0.52, y: h * 0.79 }, { x: w * 0.80, y: h * 0.79 }];
            animateStroke(ctx, pts2, INK + "0.35)", 1.5 * s, 300);
          }, 400);
        }, 100);
      }
    }

    function drawProgress(ctx, w, h) {
      ctx.lineCap = "round"; ctx.lineJoin = "round";
      var scrollTarget = ctx.canvas.closest(".section");
      var lastProg = -1;
      var s = w / 100;
      var pad = 8 * s, sw = 2 * s, dotR = 3 * s;

      function update() {
        if (!scrollTarget) return;
        var rect = scrollTarget.getBoundingClientRect();
        var prog = Math.max(0, Math.min(1, 1 - (rect.bottom / (window.innerHeight + rect.height))));
        prog = Math.max(0.05, prog);

        if (Math.abs(prog - lastProg) < 0.005) { requestAnimationFrame(update); return; }
        lastProg = prog;

        ctx.clearRect(0, 0, w, h);
        var total = 60;
        var show = Math.ceil(prog * total);

        ctx.beginPath();
        for (var i = 0; i <= total; i++) {
          var t = i / total, idx = Math.round(t * N);
          var x = pad + t * (w - 2 * pad), y = h / 2 - logoF[idx] * h * 0.34;
          if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
        }
        ctx.strokeStyle = INK + "0.06)"; ctx.lineWidth = sw; ctx.stroke();

        if (show > 1) {
          ctx.beginPath();
          for (var j = 0; j <= show; j++) {
            var t2 = j / total, idx2 = Math.round(t2 * N);
            var x2 = pad + t2 * (w - 2 * pad), y2 = h / 2 - logoF[idx2] * h * 0.34;
            if (j === 0) ctx.moveTo(x2, y2); else ctx.lineTo(x2, y2);
          }
          ctx.strokeStyle = INK + "0.55)"; ctx.lineWidth = sw; ctx.stroke();

          var tipT = show / total, tipIdx = Math.round(tipT * N);
          var tipX = pad + tipT * (w - 2 * pad), tipY = h / 2 - logoF[tipIdx] * h * 0.34;
          ctx.beginPath(); ctx.arc(tipX, tipY, dotR, 0, Math.PI * 2); ctx.fillStyle = INK + "0.4)"; ctx.fill();
        }

        requestAnimationFrame(update);
      }
      requestAnimationFrame(update);
    }

    function drawMiniCurve(ctx, ox, ow, h, sign, color, sw) {
      ctx.beginPath();
      for (var i = 0; i <= 30; i++) {
        var t = i / 30;
        var idx = Math.round(t * N);
        var d = sign > 0 ? logoF[idx] : logoB[idx];
        var x = ox + t * ow, y = h / 2 - d * h * 0.3;
        if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
      }
      ctx.strokeStyle = color; ctx.lineWidth = sw;
      ctx.lineCap = "round"; ctx.lineJoin = "round"; ctx.stroke();
    }

    function animateStroke(ctx, pts, color, sw, duration) {
      if (rm) {
        ctx.beginPath();
        pts.forEach(function(p, i) { if (i === 0) ctx.moveTo(p.x, p.y); else ctx.lineTo(p.x, p.y); });
        ctx.strokeStyle = color; ctx.lineWidth = sw; ctx.lineCap = "round"; ctx.lineJoin = "round"; ctx.stroke();
        return;
      }
      var start = performance.now();
      (function step() {
        var t = Math.min(1, (performance.now() - start) / duration);
        t = t * t * (3 - 2 * t); // smoothstep
        var show = Math.ceil(t * pts.length);
        if (show < 2) { requestAnimationFrame(step); return; }
        ctx.beginPath();
        for (var i = 0; i < show; i++) {
          if (i === 0) ctx.moveTo(pts[i].x, pts[i].y); else ctx.lineTo(pts[i].x, pts[i].y);
        }
        ctx.strokeStyle = color; ctx.lineWidth = sw; ctx.lineCap = "round"; ctx.lineJoin = "round"; ctx.stroke();
        if (t < 1) requestAnimationFrame(step);
      })();
    }
  }

  /* ── Commit plot ────────────────────────────────────────────── */

  function initCommitPlot() {
    var canvas = document.querySelector(".commit-plot");
    if (!canvas) return;
    var ctx = canvas.getContext("2d");
    var dpr = Math.min(window.devicePixelRatio || 1, 2);

    // Daily commits: Mar 16 .. Apr 10 (26 days)
    var data = [2,14,1,4,1,0,1,0,0,0,1,0,0,0,0,0,0,0,0,0,6,0,11,12,0,1];
    var maxV = 14;
    var days = data.length;

    var cw = 0, ch = 0;
    var PAD_L = 36, PAD_R = 12, PAD_T = 16, PAD_B = 28;

    function resize() {
      var r = canvas.getBoundingClientRect();
      cw = r.width; ch = r.height;
      canvas.width = cw * dpr; canvas.height = ch * dpr;
      canvas.style.width = cw + "px"; canvas.style.height = ch + "px";
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    }
    resize(); window.addEventListener("resize", resize);

    function dx(i) { return PAD_L + (i / (days - 1)) * (cw - PAD_L - PAD_R); }
    function dy(v) { return PAD_T + (1 - v / maxV) * (ch - PAD_T - PAD_B); }

    // Catmull-Rom to Bezier conversion for smooth curve
    function catmullPts(pts) {
      var out = [];
      for (var i = 0; i < pts.length - 1; i++) {
        var p0 = pts[Math.max(0, i - 1)];
        var p1 = pts[i];
        var p2 = pts[i + 1];
        var p3 = pts[Math.min(pts.length - 1, i + 2)];
        out.push({
          p: p1,
          cp1: { x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6 },
          cp2: { x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6 },
          end: p2
        });
      }
      return out;
    }

    function buildPts() {
      var pts = [];
      for (var i = 0; i < days; i++) pts.push({ x: dx(i), y: dy(data[i]) });
      return pts;
    }

    function drawFrame(prog, elapsed) {
      ctx.clearRect(0, 0, cw, ch);

      // Grid lines
      ctx.setLineDash([2, 3]);
      ctx.strokeStyle = INK + "0.06)"; ctx.lineWidth = 0.5;
      [0, 7, 14].forEach(function(v) {
        var y = dy(v);
        ctx.beginPath(); ctx.moveTo(PAD_L, y); ctx.lineTo(cw - PAD_R, y); ctx.stroke();
      });
      ctx.setLineDash([]);

      // Y-axis labels
      ctx.font = "9px ui-monospace, SFMono-Regular, SF Mono, Menlo, monospace";
      ctx.fillStyle = INK + "0.3)"; ctx.textAlign = "right";
      ctx.fillText("14", PAD_L - 6, dy(14) + 3);
      ctx.fillText("7", PAD_L - 6, dy(7) + 3);
      ctx.fillText("0", PAD_L - 6, dy(0) + 3);

      // Date labels
      ctx.textAlign = "left";
      ctx.fillText("03-16", PAD_L, ch - 6);
      ctx.textAlign = "right";
      ctx.fillText("04-10", cw - PAD_R, ch - 6);

      // Axis
      ctx.strokeStyle = INK + "0.12)"; ctx.lineWidth = 0.5;
      ctx.beginPath(); ctx.moveTo(PAD_L, PAD_T); ctx.lineTo(PAD_L, ch - PAD_B); ctx.stroke();
      ctx.beginPath(); ctx.moveTo(PAD_L, ch - PAD_B); ctx.lineTo(cw - PAD_R, ch - PAD_B); ctx.stroke();

      var pts = buildPts();
      var segs = catmullPts(pts);

      // How many segments to show based on progress
      var showSegs = Math.floor(prog * segs.length);
      var partialT = (prog * segs.length) - showSegs;
      if (showSegs >= segs.length) { showSegs = segs.length; partialT = 1; }

      if (showSegs < 1 && partialT < 0.01) return;

      // Build the visible curve path
      ctx.beginPath();
      ctx.moveTo(pts[0].x, pts[0].y);
      for (var s = 0; s < showSegs; s++) {
        var seg = segs[s];
        if (s === showSegs - 1 && showSegs < segs.length) {
          // Partial last visible segment (not needed when fully shown)
        }
        ctx.bezierCurveTo(seg.cp1.x, seg.cp1.y, seg.cp2.x, seg.cp2.y, seg.end.x, seg.end.y);
      }
      // Partial segment at the frontier
      if (showSegs < segs.length && partialT > 0.01) {
        var seg2 = segs[showSegs];
        var t = partialT;
        // De Casteljau split for partial bezier
        var sx = seg2.p.x, sy = seg2.p.y;
        var c1x = seg2.cp1.x, c1y = seg2.cp1.y;
        var c2x = seg2.cp2.x, c2y = seg2.cp2.y;
        var ex = seg2.end.x, ey = seg2.end.y;
        var m1x = sx + (c1x - sx) * t, m1y = sy + (c1y - sy) * t;
        var m2x = c1x + (c2x - c1x) * t, m2y = c1y + (c2y - c1y) * t;
        var m3x = c2x + (ex - c2x) * t, m3y = c2y + (ey - c2y) * t;
        var n1x = m1x + (m2x - m1x) * t, n1y = m1y + (m2y - m1y) * t;
        var n2x = m2x + (m3x - m2x) * t, n2y = m2y + (m3y - m2y) * t;
        var px = n1x + (n2x - n1x) * t, py = n1y + (n2y - n1y) * t;
        ctx.bezierCurveTo(m1x, m1y, n1x, n1y, px, py);
      }

      // Stroke the curve
      ctx.strokeStyle = INK + "0.65)"; ctx.lineWidth = 2;
      ctx.lineCap = "round"; ctx.lineJoin = "round"; ctx.stroke();

      // Fill area under curve
      var lastIdx = Math.min(showSegs, days - 1);
      if (showSegs < segs.length && partialT > 0.01) {
        // Tip of partial segment
        var seg3 = segs[showSegs];
        var t2 = partialT;
        var _sx = seg3.p.x, _c1x = seg3.cp1.x, _c2x = seg3.cp2.x, _ex = seg3.end.x;
        var _m1x = _sx + (_c1x - _sx) * t2;
        var _m2x = _c1x + (_c2x - _c1x) * t2;
        var _m3x = _c2x + (_ex - _c2x) * t2;
        var _n1x = _m1x + (_m2x - _m1x) * t2;
        var _n2x = _m2x + (_m3x - _m2x) * t2;
        var tipX = _n1x + (_n2x - _n1x) * t2;
        ctx.lineTo(tipX, ch - PAD_B);
      } else {
        ctx.lineTo(pts[lastIdx].x, ch - PAD_B);
      }
      ctx.lineTo(pts[0].x, ch - PAD_B);
      ctx.closePath();
      var grad = ctx.createLinearGradient(0, PAD_T, 0, ch - PAD_B);
      grad.addColorStop(0, INK + "0.10)");
      grad.addColorStop(1, INK + "0.01)");
      ctx.fillStyle = grad;
      ctx.fill();

      // Data dots
      var dotsToShow = showSegs + 1;
      for (var d = 0; d < Math.min(dotsToShow, days); d++) {
        if (data[d] === 0) continue;
        var isLast = (d === days - 1);
        var r = isLast ? 4 : 2.5;
        ctx.beginPath(); ctx.arc(pts[d].x, pts[d].y, r, 0, Math.PI * 2);
        if (isLast) {
          // Pulse on "now" dot
          var pulse = 0.4 + Math.sin(elapsed * 2) * 0.2;
          ctx.fillStyle = "rgba(30, 74, 168, " + pulse + ")";
          ctx.fill();
          ctx.beginPath(); ctx.arc(pts[d].x, pts[d].y, r + 4 + Math.sin(elapsed * 2) * 2, 0, Math.PI * 2);
          ctx.strokeStyle = "rgba(30, 74, 168, 0.12)"; ctx.lineWidth = 1; ctx.stroke();
        } else {
          ctx.fillStyle = INK + "0.55)";
          ctx.fill();
        }
      }

      // Max label
      if (prog > 0.15) {
        ctx.globalAlpha = Math.min(1, (prog - 0.15) / 0.2);
        ctx.fillStyle = "rgba(30, 74, 168, 0.7)";
        ctx.textAlign = "left";
        ctx.fillText("peak = 14", dx(1) + 8, dy(14) - 6);
        ctx.globalAlpha = 1;
      }
    }

    // Animate on scroll into view
    var started = false, startT = 0;
    var obs = new IntersectionObserver(function(entries) {
      if (entries[0].isIntersecting && !started) {
        started = true; startT = performance.now();
        obs.disconnect();
        if (rm) { drawFrame(1, 0); return; }
        (function loop() {
          var elapsed = (performance.now() - startT) / 1000;
          var prog = Math.min(elapsed / 1.6, 1);
          prog = prog * prog * (3 - 2 * prog); // smoothstep
          drawFrame(prog, elapsed);
          if (prog < 1) requestAnimationFrame(loop);
          else {
            // Keep animating for the pulse dot
            (function pulse() { drawFrame(1, (performance.now() - startT) / 1000); requestAnimationFrame(pulse); })();
          }
        })();
      }
    }, { threshold: 0.15 });
    obs.observe(canvas);
  }

  /* ── Init ──────────────────────────────────────────────────── */
  initReveals(); initAnchors(); initGrain(); initHeroLogo(); initMotifs(); initCommitPlot(); initCopy();
})();
