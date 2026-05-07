// Paper-design shaders, vanilla. Loaded from esm.sh — no build step.
// Hero: dark mesh gradient with one accent.
// Sigil: liquid metal of the Clome mark.

import {
  ShaderMount,
  meshGradientFragmentShader,
  liquidMetalFragmentShader,
  getShaderColorFromString,
  defaultObjectSizing,
} from "https://esm.sh/@paper-design/shaders@0.0.76";
import * as THREE from "https://esm.sh/three@0.171.0";

const reduceMotion = window.matchMedia(
  "(prefers-reduced-motion: reduce)"
).matches;

// ---------- HERO ----------
const heroEl = document.querySelector('[data-shader="hero"]');
if (heroEl) {
  // Mostly black, with one warm accent — keeps the page B&W with a single
  // colored breath in the hero.
  // mostly mono. one sky-blue stop carries through the gradient as a single
  // colored breath — mostly visible where the gradient peaks.
  const colors = [
    "#040404",
    "#0e0e0e",
    "#1d1d1d",
    "#2c2c2c",
    "#3a4a58",
    "#77a7c5",
  ].map((c) => getShaderColorFromString(c));

  new ShaderMount(
    heroEl,
    meshGradientFragmentShader,
    {
      u_colors: colors,
      u_colorsCount: colors.length,
      u_distortion: 1.0,
      u_swirl: 0.75,
      u_grainMixer: 0.22,
      u_grainOverlay: 0.05,
      // explicit u_-prefixed sizing — defaultObjectSizing exports bare keys
      u_fit: 2, // 2 = cover (mesh fills the hero canvas)
      u_scale: 1.25,
      u_rotation: -18,
      u_offsetX: 0,
      u_offsetY: 0,
      u_originX: 0.5,
      u_originY: 0.5,
      u_worldWidth: 0,
      u_worldHeight: 0,
    },
    { antialias: true, premultipliedAlpha: false },
    reduceMotion ? 0 : 0.18
  );
}

// ---------- SIGIL (liquid metal of the clome logo) ----------
const sigilEl = document.querySelector('[data-shader="sigil"]');
if (sigilEl) {
  // mount only after image loaded — u_image must exist in providedUniforms
  // at construction time so its location gets cached.
  loadImage("./clome-logo-mask.png?v=6")
    .then((img) => {
      console.log(
        "[sigil] image loaded:",
        img.naturalWidth + "x" + img.naturalHeight
      );
      new ShaderMount(
        sigilEl,
        liquidMetalFragmentShader,
        {
          // transparent so the cloud shader behind shows through everywhere
          // except the logo glyph itself
          u_colorBack: getShaderColorFromString("rgba(0,0,0,0)"),
          u_colorTint: getShaderColorFromString("#dfeaf2"),
          u_softness: 0.85,
          u_repetition: 3.5,
          u_shiftRed: 0.3,
          u_shiftBlue: 0.7,
          u_distortion: 0.55,
          u_contour: 0.45,
          u_angle: 0,
          u_shape: 0, // 0 = use image
          u_isImage: true,
          u_image: img,
          u_imageAspectRatio: img.naturalWidth / img.naturalHeight || 1,
          u_fit: 1, // 1 = contain
          u_scale: 0.92,
          u_rotation: 0,
          u_offsetX: 0,
          u_offsetY: 0,
          u_originX: 0.5,
          u_originY: 0.5,
          u_worldWidth: 0,
          u_worldHeight: 0,
        },
        { antialias: true, premultipliedAlpha: false },
        reduceMotion ? 0 : 0.4,
        0,
        2,
        1920 * 1080 * 4,
        ["u_image"]
      );
    })
    .catch((err) => {
      console.warn("[sigil] image load failed:", err);
    });
}

function loadImage(url) {
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.crossOrigin = "anonymous";
    img.onload = () => resolve(img);
    img.onerror = (e) => reject(new Error("image load failed: " + url));
    img.src = url;
  });
}

// ---------- SIGIL CLOUD BG (ported from Framer Cloud — WebGL FBM) ----------
// source: https://framer.com/m/Cloud-2n2V.js
// sits behind the liquid-metal sigil. Screen-blended at low opacity so the
// dark page tone stays intact and only highlights bleed through.
const cloudEl = document.querySelector('[data-shader="cloud"]');
if (cloudEl) initCloudShader(cloudEl, reduceMotion ? 0 : 1);

function initCloudShader(container, speed) {
  // GLSL ported verbatim from the Framer module. Uniform names preserved.
  const fragmentShader = `
    precision mediump float;
    uniform float u_time;
    uniform vec2 u_resolution;
    uniform float u_density;
    uniform float u_speed;
    uniform float u_rotation;
    uniform int u_layers;

    float hash(vec2 p) {
      p = fract(p * vec2(123.34, 456.21));
      p += dot(p, p + 78.233);
      return fract(p.x * p.y);
    }
    float noise(vec2 p) {
      vec2 i = floor(p);
      vec2 f = fract(p);
      f = f * f * (3.0 - 2.0 * f);
      return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
                 mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
    }
    float fbm(vec2 p, float density) {
      float v = 0.0;
      float a = 0.5;
      vec2 shift = vec2(100);
      for (int i = 0; i < 5; i++) {
        if (float(i) >= density) break;
        v += a * noise(p);
        p = p * 2.0 + shift;
        a *= 0.5;
      }
      return v;
    }

    void main() {
      vec2 uv = gl_FragCoord.xy / u_resolution.xy;
      uv -= 0.5;
      uv = mat2(cos(u_rotation), -sin(u_rotation), sin(u_rotation), cos(u_rotation)) * uv;
      uv += 0.5;

      vec3 color = vec3(0.6, 0.8, 1.0);
      float cloud = 0.0;
      if (u_layers >= 1) {
        float n1 = fbm(uv * 3.0 + u_time * u_speed * 0.05, u_density);
        cloud += smoothstep(0.4, 0.6, n1);
      }
      if (u_layers >= 2) {
        float n2 = fbm(uv * 3.0 + u_time * (u_speed * 0.1) * 0.07, u_density);
        cloud += smoothstep(0.4, 0.6, n2);
      }
      if (u_layers == 3) {
        float n3 = fbm(uv * 3.0 + u_time * (u_speed * 0.2) * 0.09, u_density);
        cloud += smoothstep(0.4, 0.6, n3);
      }
      cloud /= float(u_layers);
      color = mix(color, vec3(1.0), cloud);
      gl_FragColor = vec4(color, 1.0);
    }
  `;
  const vertexShader = `
    void main() {
      gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
    }
  `;

  const w = container.clientWidth || 800;
  const h = container.clientHeight || 600;
  const scene = new THREE.Scene();
  const camera = new THREE.OrthographicCamera(-1, 1, 1, -1, 0.1, 10);
  camera.position.z = 1;
  const renderer = new THREE.WebGLRenderer({ alpha: true, antialias: false });
  renderer.setSize(w, h);
  renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
  container.appendChild(renderer.domElement);

  const uniforms = {
    u_time: { value: 0 },
    u_resolution: { value: new THREE.Vector2(w, h) },
    u_density: { value: 5.0 },
    u_speed: { value: 1.0 },
    u_rotation: { value: 0.0 },
    u_layers: { value: 3 },
  };
  const material = new THREE.ShaderMaterial({
    uniforms,
    vertexShader,
    fragmentShader,
  });
  scene.add(new THREE.Mesh(new THREE.PlaneGeometry(2, 2), material));

  // initial paint (also the only frame if reduceMotion)
  renderer.render(scene, camera);

  const clock = new THREE.Clock();
  let raf = 0;
  let visible = false;
  const tick = () => {
    if (!visible || speed === 0) {
      raf = 0;
      return;
    }
    raf = requestAnimationFrame(tick);
    uniforms.u_time.value += clock.getDelta() * speed;
    renderer.render(scene, camera);
  };

  new IntersectionObserver(
    (entries) => {
      visible = entries[0].isIntersecting;
      if (visible && speed > 0 && !raf) {
        clock.getDelta(); // discard accumulated dt while off-screen
        tick();
      }
    },
    { rootMargin: "200px 0px" }
  ).observe(container);

  new ResizeObserver(() => {
    const nw = container.clientWidth;
    const nh = container.clientHeight;
    renderer.setSize(nw, nh);
    uniforms.u_resolution.value.set(nw, nh);
  }).observe(container);
}

// ---------- PLATES (ASCII FlowTrail — ported from Framer Ascii_FlowTrail) ----------
// source: https://framer.com/m/Ascii-FlowTrail-1wMf.js
// 2D canvas, no WebGL — cursor leaves an ASCII trail across each plate.
const plateEls = document.querySelectorAll('[data-shader="plate"]');
plateEls.forEach((el) => initFlowTrail(el));

function initFlowTrail(container) {
  const canvas = document.createElement("canvas");
  container.appendChild(canvas);
  const ctx = canvas.getContext("2d");

  // tuned for screenshot-section bg — sky tint, low overall opacity, soft trail
  const opts = {
    glyphSet: 3,            // 0 dots, 1 squares, 2 blocks, 3 patterned, 4 diamonds
    scale: 50,              // % — character size
    gamma: 0,
    mix: 32,                // % — overall opacity
    invertOrder: true,
    radius: 28,             // % — trail influence radius
    strength: 65,           // % — trail intensity
    turbulence: 70,         // %
    tint: "#77a7c5",        // sky accent
    tail: 100,              // % — trail length
    drawBlendMode: "Screen",
    momentum: 60,           // % — smoothing
  };

  const dpr = Math.min(window.devicePixelRatio || 1, 2);
  let cw = 0, ch = 0;

  const resize = () => {
    const rect = container.getBoundingClientRect();
    cw = rect.width;
    ch = rect.height;
    canvas.width = Math.max(1, Math.floor(cw * dpr));
    canvas.height = Math.max(1, Math.floor(ch * dpr));
    canvas.style.width = cw + "px";
    canvas.style.height = ch + "px";
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  };
  resize();
  new ResizeObserver(resize).observe(container);

  const baseSets = [
    "●•·. ",                  // dots
    "■□▪▫ ",             // squares
    "█▓▒░ ",             // blocks
    "▣▤▥▦▧▨▩ ", // patterned
    "◆◇◈○◉◊◌ ", // diamonds
  ];
  const baseChars = baseSets[opts.glyphSet] || "@%#*+=-:. ";
  const chars = opts.invertOrder
    ? [...baseChars].reverse().join("")
    : baseChars;

  const tintR = parseInt(opts.tint.slice(1, 3), 16);
  const tintG = parseInt(opts.tint.slice(3, 5), 16);
  const tintB = parseInt(opts.tint.slice(5, 7), 16);
  const bayer = [[0,8,2,10],[12,4,14,6],[3,11,1,9],[15,7,13,5]];

  let mouseX = -9999, mouseY = -9999;
  let smoothX = -9999, smoothY = -9999;
  let trail = [];
  let time = 0;
  let visible = false;
  let raf = 0;

  const onMove = (e) => {
    const rect = container.getBoundingClientRect();
    mouseX = e.clientX - rect.left;
    mouseY = e.clientY - rect.top;
    if (smoothX < -9000) {
      smoothX = mouseX;
      smoothY = mouseY;
    }
  };
  window.addEventListener("pointermove", onMove, { passive: true });

  const animate = () => {
    if (!visible || reduceMotion) {
      raf = 0;
      return;
    }
    raf = requestAnimationFrame(animate);
    time += 0.016;

    ctx.clearRect(0, 0, cw, ch);

    // momentum easing — original formula
    if (smoothX > -9000) {
      const k = 1 - (opts.momentum / 100) * 0.95;
      smoothX += (mouseX - smoothX) * k;
      smoothY += (mouseY - smoothY) * k;

      // only push when smoothed cursor actually moved — avoids permanent
      // glow when pointer rests on one plate while user reads another
      const last = trail[trail.length - 1];
      if (!last || Math.hypot(last.x - smoothX, last.y - smoothY) > 0.5) {
        trail.push({ x: smoothX, y: smoothY, life: 1 });
      }
    }

    const maxLength = Math.floor(opts.tail / 100 * 50) + 5;
    while (trail.length > maxLength) trail.shift();
    const decay = 0.02 * (1 - opts.tail / 100) + 0.01;
    for (const p of trail) p.life -= decay;
    trail = trail.filter((p) => p.life > 0);

    if (trail.length === 0) return;

    const charSize = Math.max(6, Math.floor(16 * opts.scale / 100));
    ctx.font = `${charSize}px ui-monospace, "SF Mono", Menlo, monospace`;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";

    const blend = opts.drawBlendMode;
    const cols = Math.ceil(cw / charSize);
    const rows = Math.ceil(ch / charSize);
    const maxDist = (opts.radius / 100) * 150;

    for (let row = 0; row < rows; row++) {
      for (let col = 0; col < cols; col++) {
        const x = col * charSize + charSize / 2;
        const y = row * charSize + charSize / 2;

        let intensity = 0;
        for (let i = 0; i < trail.length; i++) {
          const p = trail[i];
          const dx = x - p.x, dy = y - p.y;
          const dist = Math.sqrt(dx * dx + dy * dy);
          if (dist >= maxDist) continue;
          const v = (1 - dist / maxDist) * p.life * (opts.strength / 100);
          if (blend === "Add") intensity += v;
          else if (blend === "Multiply") intensity *= v;
          else if (blend === "Difference") intensity = Math.abs(intensity - v);
          else if (blend === "Screen") intensity = 1 - (1 - intensity) * (1 - v);
          else intensity = Math.max(intensity, v);
        }
        if (intensity <= 0) continue;

        if (opts.turbulence > 0) {
          intensity +=
            Math.sin(x * 0.01 + time) *
            Math.cos(y * 0.01 + time * 0.7) *
            (opts.turbulence / 1000);
        }
        if (opts.gamma !== 0) {
          intensity = Math.pow(Math.max(intensity, 0), 1 - opts.gamma);
        }
        if (opts.glyphSet === 3) {
          const t = bayer[row & 3][col & 3] / 16;
          intensity = intensity > t ? 1 : intensity * 0.5;
        }

        intensity = Math.max(0, Math.min(1, intensity));
        if (intensity <= 0.01) continue;

        const ci = Math.min(chars.length - 1, Math.floor(intensity * chars.length));
        const alpha = intensity * (opts.mix / 100);
        ctx.fillStyle = `rgba(${tintR}, ${tintG}, ${tintB}, ${alpha})`;
        ctx.fillText(chars[ci], x, y);
      }
    }
  };

  new IntersectionObserver(
    (entries) => {
      visible = entries[0].isIntersecting;
      if (visible && !reduceMotion && !raf) raf = requestAnimationFrame(animate);
    },
    { rootMargin: "120px 0px" }
  ).observe(container);
}

// ---------- FOOTER (ASCII shader, ported from Framer/Framerusercontent) ----------
const footerEl = document.querySelector('[data-shader="footer"]');
if (footerEl) {
  initAsciiShader(footerEl, reduceMotion ? 0 : 0.7);
}

function initAsciiShader(container, speed) {
  const vertexShader = `
    varying vec2 vUv;
    void main() {
      vUv = uv;
      gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
    }
  `;

  // Original ASCII shader. Sky-blue scanline tint replaces the green
  // Matrix-rain color (vec3(0.,1.,0.) → sky #77a7c5).
  const fragmentShader = `
    precision mediump float;
    uniform vec2 iResolution;
    uniform float iTime;
    float time;

    float noise(vec2 p) {
      return sin(p.x*10.) * sin(p.y*(3. + sin(time/11.))) + .2;
    }
    mat2 rotate(float angle) {
      return mat2(cos(angle), -sin(angle), sin(angle), cos(angle));
    }
    float fbm(vec2 p) {
      p *= 1.1;
      float f = 0.;
      float amp = .5;
      for (int i = 0; i < 3; i++) {
        mat2 modify = rotate(time/50. * float(i*i));
        f += amp*noise(p);
        p = modify * p;
        p *= 2.;
        amp /= 2.2;
      }
      return f;
    }
    float pattern(vec2 p, out vec2 q, out vec2 r) {
      q = vec2(fbm(p + vec2(1.)), fbm(rotate(.1*time)*p + vec2(1.)));
      r = vec2(fbm(rotate(.1)*q + vec2(0.)), fbm(q + vec2(0.)));
      return fbm(p + 1.*r);
    }
    float digit(vec2 p) {
      vec2 grid = vec2(3.,1.) * 15.;
      vec2 s = floor(p * grid) / grid;
      p = p * grid;
      vec2 q;
      vec2 r;
      float intensity = pattern(s/10., q, r)*1.3 - 0.03;
      p = fract(p);
      p *= vec2(1.2, 1.2);
      float x = fract(p.x * 5.);
      float y = fract((1. - p.y) * 5.);
      int i = int(floor((1. - p.y) * 5.));
      int j = int(floor(p.x * 5.));
      int n = (i-2)*(i-2)+(j-2)*(j-2);
      float f = float(n)/16.;
      float isOn = intensity - f > 0.1 ? 1. : 0.;
      return p.x <= 1. && p.y <= 1. ? isOn * (0.2 + y*4./5.) * (0.75 + x/4.) : 0.;
    }
    float onOff(float a, float b, float c) {
      return step(c, sin(iTime + a*cos(iTime*b)));
    }
    float displace(vec2 look) {
      float y = (look.y-mod(iTime/4.,1.));
      float window = 1./(1.+50.*y*y);
      return sin(look.y*20. + iTime)/80.*onOff(4.,2.,.8)*(1.+cos(iTime*60.))*window;
    }
    vec3 getColor(vec2 p) {
      float bar = mod(p.y + time*20., 1.) < 0.2 ? 1.4 : 1.;
      p.x += displace(p);
      float middle = digit(p);
      float off = 0.002;
      float sum = 0.;
      for (float i = -1.; i < 2.; i+=1.) {
        for (float j = -1.; j < 2.; j+=1.) {
          sum += digit(p+vec2(off*i, off*j));
        }
      }
      // sky tint instead of green; off-white for the digit itself.
      return vec3(0.96, 0.96, 0.94)*middle + sum/10.*vec3(0.466, 0.654, 0.772) * bar;
    }
    void mainImage(out vec4 fragColor, in vec2 fragCoord) {
      time = iTime / 3.;
      vec2 p = fragCoord / iResolution.xy;
      vec3 col = getColor(p);
      fragColor = vec4(col, 1.);
    }
    void main() {
      mainImage(gl_FragColor, gl_FragCoord.xy);
    }
  `;

  const w = container.clientWidth || 800;
  const h = container.clientHeight || 320;

  const scene = new THREE.Scene();
  const camera = new THREE.OrthographicCamera(-1, 1, 1, -1, 0.1, 10);
  camera.position.z = 1;
  const renderer = new THREE.WebGLRenderer({ alpha: true, antialias: true });
  renderer.setSize(w, h);
  renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
  container.appendChild(renderer.domElement);

  const uniforms = {
    iResolution: { value: new THREE.Vector2(w, h) },
    iTime: { value: 0 },
  };
  const material = new THREE.ShaderMaterial({
    uniforms,
    vertexShader,
    fragmentShader,
    transparent: true,
  });
  const mesh = new THREE.Mesh(new THREE.PlaneGeometry(2, 2), material);
  scene.add(mesh);

  const clock = new THREE.Clock();
  let raf = 0;
  const tick = () => {
    raf = requestAnimationFrame(tick);
    uniforms.iTime.value += clock.getDelta() * speed;
    renderer.render(scene, camera);
  };
  if (speed > 0) tick();
  else renderer.render(scene, camera);

  const ro = new ResizeObserver(() => {
    const nw = container.clientWidth;
    const nh = container.clientHeight;
    renderer.setSize(nw, nh);
    uniforms.iResolution.value.set(nw, nh);
  });
  ro.observe(container);
}

// ---------- subtle scroll cue on the hero shader (parallax) ----------
if (heroEl && !reduceMotion) {
  let raf = 0;
  const onScroll = () => {
    if (raf) return;
    raf = requestAnimationFrame(() => {
      raf = 0;
      const y = window.scrollY;
      const max = window.innerHeight;
      const t = Math.min(1, y / max);
      heroEl.style.transform = `translate3d(0, ${t * -40}px, 0) scale(${
        1 + t * 0.04
      })`;
    });
  };
  window.addEventListener("scroll", onScroll, { passive: true });
}
