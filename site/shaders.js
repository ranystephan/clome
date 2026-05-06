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
          u_colorBack: getShaderColorFromString("#0a0a0a"),
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
