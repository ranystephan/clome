// ═══════════════════════════════════════════════════════════════
// Clome Landing Page — Global Animations & Interactions
// GSAP + ScrollTrigger | Zajno-inspired choreography
// ═══════════════════════════════════════════════════════════════

gsap.registerPlugin(ScrollTrigger);

(function () {
  "use strict";

  // ───────────────────────────────────────────────────────────
  // 0. CONFIGURATION
  // ───────────────────────────────────────────────────────────
  const EASE_DEFAULT = "power3.out";
  const EASE_ELASTIC = "elastic.out(1, 0.5)";
  const COPPER_RGB = "181, 97, 63";
  const IS_DESKTOP = window.innerWidth > 900;
  const PREFERSREDUCED = window.matchMedia(
    "(prefers-reduced-motion: reduce)"
  ).matches;

  // ───────────────────────────────────────────────────────────
  // 1. CURSOR GLOW (desktop only)
  // ───────────────────────────────────────────────────────────
  function initCursorGlow() {
    if (!IS_DESKTOP || PREFERSREDUCED) return;

    const glow = document.createElement("div");
    glow.id = "cursor-glow";
    Object.assign(glow.style, {
      position: "fixed",
      top: 0,
      left: 0,
      width: "400px",
      height: "400px",
      borderRadius: "50%",
      background: `radial-gradient(circle, rgba(${COPPER_RGB}, 0.06) 0%, rgba(${COPPER_RGB}, 0.02) 40%, transparent 70%)`,
      pointerEvents: "none",
      zIndex: "9999",
      transform: "translate(-50%, -50%)",
      opacity: 0,
      willChange: "transform",
      mixBlendMode: "screen",
    });
    document.body.appendChild(glow);

    // Fade in once mouse enters window
    let visible = false;
    document.addEventListener(
      "mousemove",
      (e) => {
        gsap.to(glow, {
          x: e.clientX,
          y: e.clientY,
          duration: 0.5,
          ease: "power2.out",
          overwrite: "auto",
        });

        if (!visible) {
          visible = true;
          gsap.to(glow, { opacity: 1, duration: 0.6, ease: EASE_DEFAULT });
        }
      },
      { passive: true }
    );

    // Fade out when mouse leaves window
    document.addEventListener("mouseleave", () => {
      visible = false;
      gsap.to(glow, { opacity: 0, duration: 0.4, ease: EASE_DEFAULT });
    });
  }

  // ───────────────────────────────────────────────────────────
  // 2. NAV — backdrop-blur + background on scroll
  // ───────────────────────────────────────────────────────────
  function initNav() {
    const nav = document.getElementById("nav");
    if (!nav) return;

    // Scroll-triggered class toggle via GSAP
    ScrollTrigger.create({
      trigger: document.body,
      start: "80px top",
      onEnter: () => nav.classList.add("scrolled"),
      onLeaveBack: () => nav.classList.remove("scrolled"),
    });

    // Brand logo hover rotate (CSS handles base, GSAP adds spring feel)
    const brandImg = nav.querySelector(".nav-brand img");
    if (brandImg) {
      brandImg.addEventListener("mouseenter", () => {
        gsap.to(brandImg, {
          rotation: -12,
          scale: 1.08,
          duration: 0.5,
          ease: EASE_ELASTIC,
        });
      });
      brandImg.addEventListener("mouseleave", () => {
        gsap.to(brandImg, {
          rotation: 0,
          scale: 1,
          duration: 0.5,
          ease: EASE_DEFAULT,
        });
      });
    }
  }

  // ───────────────────────────────────────────────────────────
  // 3. SCROLL REVEALS — clip-path + transform with stagger
  // ───────────────────────────────────────────────────────────
  function initScrollReveals() {
    const reveals = gsap.utils.toArray("[data-reveal]");
    if (!reveals.length) return;

    // Group reveals by parent to enable stagger among siblings
    const parentMap = new Map();
    reveals.forEach((el) => {
      const parent = el.parentElement;
      if (!parentMap.has(parent)) parentMap.set(parent, []);
      parentMap.get(parent).push(el);
    });

    parentMap.forEach((siblings, parent) => {
      siblings.forEach((el, idx) => {
        const dir = el.getAttribute("data-reveal") || "up";
        const isSpecial = el.classList.contains("sec-label");

        // Starting state
        const fromVars = {
          opacity: 0,
          clipPath: "inset(0 0 100% 0)",
        };

        // Direction-specific transforms
        if (dir === "up" || dir === "") {
          fromVars.y = 48;
        } else if (dir === "left") {
          fromVars.x = -64;
          fromVars.clipPath = "inset(0 100% 0 0)";
        } else if (dir === "right") {
          fromVars.x = 64;
          fromVars.clipPath = "inset(0 0 0 100%)";
        }

        const toVars = {
          opacity: 1,
          y: 0,
          x: 0,
          clipPath: "inset(0 0 0 0)",
          duration: PREFERSREDUCED ? 0.01 : 1,
          delay: idx * 0.1,
          ease: isSpecial ? EASE_ELASTIC : EASE_DEFAULT,
          onComplete: () => {
            // Clean up inline styles after animation to let CSS take over
            el.style.clipPath = "";
            el.classList.add("visible");
          },
        };

        gsap.set(el, fromVars);

        ScrollTrigger.create({
          trigger: el,
          start: "top 88%",
          once: true,
          onEnter: () => gsap.to(el, toVars),
        });
      });
    });
  }

  // ───────────────────────────────────────────────────────────
  // 4. MARQUEE — GSAP-driven infinite scroll, pause on hover
  // ───────────────────────────────────────────────────────────
  function initMarquee() {
    const track = document.querySelector(".marquee-track");
    if (!track) return;

    // Kill the CSS animation, GSAP takes over
    track.style.animation = "none";

    // Measure the width of the content (half, since it's duplicated)
    const items = track.querySelectorAll(".marquee-item");
    const halfCount = items.length / 2;
    let contentWidth = 0;
    for (let i = 0; i < halfCount; i++) {
      contentWidth += items[i].offsetWidth + 36; // approx padding
    }

    // Use a simple repeating tween
    const marqueeTween = gsap.to(track, {
      x: -contentWidth,
      duration: 35,
      ease: "none",
      repeat: -1,
      modifiers: {
        x: gsap.utils.unitize((x) => {
          return parseFloat(x) % contentWidth;
        }),
      },
    });

    // Pause/resume on hover
    const marqueeEl = track.closest(".marquee");
    if (marqueeEl) {
      marqueeEl.addEventListener("mouseenter", () => {
        gsap.to(marqueeTween, {
          timeScale: 0,
          duration: 0.6,
          ease: EASE_DEFAULT,
        });
      });
      marqueeEl.addEventListener("mouseleave", () => {
        gsap.to(marqueeTween, {
          timeScale: 1,
          duration: 0.6,
          ease: EASE_DEFAULT,
        });
      });
    }
  }

  // ───────────────────────────────────────────────────────────
  // 5. FEATURE CARDS — magnetic hover on .n element
  // ───────────────────────────────────────────────────────────
  function initFeatureCards() {
    const cards = gsap.utils.toArray(".feat-card");
    if (!cards.length || !IS_DESKTOP) return;

    cards.forEach((card) => {
      const num = card.querySelector(".n");
      if (!num) return;

      // Magnetic hover: number follows mouse within card bounds
      card.addEventListener(
        "mousemove",
        (e) => {
          const rect = card.getBoundingClientRect();
          // Normalize mouse position within card: -1 to 1
          const px = (e.clientX - rect.left) / rect.width;
          const py = (e.clientY - rect.top) / rect.height;
          const mx = (px - 0.5) * 2;
          const my = (py - 0.5) * 2;

          // Magnetic pull range (pixels)
          const pullX = mx * 18;
          const pullY = my * 14;

          gsap.to(num, {
            x: pullX,
            y: pullY,
            duration: 0.4,
            ease: "power2.out",
            overwrite: "auto",
          });
        },
        { passive: true }
      );

      card.addEventListener("mouseleave", () => {
        gsap.to(num, {
          x: 0,
          y: 0,
          duration: 0.6,
          ease: EASE_ELASTIC,
        });
      });

      // Card entry: subtle scale lift
      card.addEventListener("mouseenter", () => {
        gsap.to(num, {
          scale: 1.05,
          duration: 0.4,
          ease: EASE_DEFAULT,
        });
      });
      card.addEventListener("mouseleave", () => {
        gsap.to(num, {
          scale: 1,
          duration: 0.5,
          ease: EASE_DEFAULT,
        });
      });
    });
  }

  // ───────────────────────────────────────────────────────────
  // 6. ARCHITECTURE LAYERS — staggered entry + parallax
  // ───────────────────────────────────────────────────────────
  function initArchLayers() {
    const layers = gsap.utils.toArray(".arch-layer");
    if (!layers.length) return;

    // Staggered entry from the right
    gsap.set(layers, { opacity: 0, x: 60 });

    ScrollTrigger.create({
      trigger: ".arch-stack",
      start: "top 80%",
      once: true,
      onEnter: () => {
        gsap.to(layers, {
          opacity: 1,
          x: 0,
          duration: 0.8,
          stagger: 0.08,
          ease: EASE_DEFAULT,
        });
      },
    });

    // Subtle parallax: each layer moves at different speed on scroll
    if (!PREFERSREDUCED) {
      layers.forEach((layer, i) => {
        const speed = 0.12 + i * 0.06; // increasing parallax depth
        gsap.to(layer, {
          y: () => -speed * 40,
          ease: "none",
          scrollTrigger: {
            trigger: ".arch-stack",
            start: "top bottom",
            end: "bottom top",
            scrub: 1.2,
          },
        });
      });
    }
  }

  // ───────────────────────────────────────────────────────────
  // 7. SMOOTH ANCHOR SCROLL — nav links
  // ───────────────────────────────────────────────────────────
  function initSmoothScroll() {
    document.querySelectorAll('a[href^="#"]').forEach((link) => {
      link.addEventListener("click", (e) => {
        const target = document.querySelector(link.getAttribute("href"));
        if (!target) return;
        e.preventDefault();

        gsap.to(window, {
          scrollTo: {
            y: target,
            offsetY: 72, // nav height
          },
          duration: 1.2,
          ease: "power3.inOut",
          // Fallback if ScrollToPlugin isn't loaded
          onStart: function () {
            if (!gsap.plugins || !gsap.plugins.scrollTo) {
              // Manual smooth scroll fallback
              this.kill();
              target.scrollIntoView({ behavior: "smooth" });
            }
          },
        });
      });
    });

    // Fallback: plain smooth scroll if ScrollTo plugin not available
    if (typeof gsap.plugins === "undefined" || !gsap.plugins.scrollTo) {
      document.querySelectorAll('a[href^="#"]').forEach((link) => {
        link.addEventListener("click", (e) => {
          const target = document.querySelector(link.getAttribute("href"));
          if (!target) return;
          e.preventDefault();
          const y =
            target.getBoundingClientRect().top + window.scrollY - 72;
          window.scrollTo({ top: y, behavior: "smooth" });
        });
      });
    }
  }

  // ───────────────────────────────────────────────────────────
  // 8. FEATURE GRID — scroll-triggered stagger reveal
  // ───────────────────────────────────────────────────────────
  function initFeatureGridReveal() {
    const cards = gsap.utils.toArray(".feat-card");
    if (!cards.length) return;

    gsap.set(cards, { opacity: 0, y: 40, scale: 0.97 });

    ScrollTrigger.create({
      trigger: ".feat-grid",
      start: "top 78%",
      once: true,
      onEnter: () => {
        gsap.to(cards, {
          opacity: 1,
          y: 0,
          scale: 1,
          duration: 0.8,
          stagger: {
            each: 0.1,
            grid: [2, 3],
            from: "start",
          },
          ease: EASE_DEFAULT,
        });
      },
    });
  }

  // ───────────────────────────────────────────────────────────
  // 9. OSS CARD — border glow pulse on scroll enter
  // ───────────────────────────────────────────────────────────
  function initOSSCard() {
    const ossCard = document.querySelector(".oss-card");
    if (!ossCard) return;

    ScrollTrigger.create({
      trigger: ossCard,
      start: "top 80%",
      once: true,
      onEnter: () => {
        gsap.fromTo(
          ossCard,
          { boxShadow: "0 0 0 0 rgba(181,97,63,0)" },
          {
            boxShadow: "0 0 80px rgba(181,97,63,0.12)",
            duration: 1.5,
            ease: EASE_DEFAULT,
          }
        );
      },
    });
  }

  // ───────────────────────────────────────────────────────────
  // 10. CTA SECTION — text reveal
  // ───────────────────────────────────────────────────────────
  function initCTA() {
    const ctaH2 = document.querySelector(".cta h2");
    if (!ctaH2) return;

    ScrollTrigger.create({
      trigger: ".cta",
      start: "top 75%",
      once: true,
      onEnter: () => {
        gsap.fromTo(
          ctaH2,
          {
            scale: 0.85,
            opacity: 0,
            filter: "blur(8px)",
          },
          {
            scale: 1,
            opacity: 1,
            filter: "blur(0px)",
            duration: 1,
            ease: EASE_DEFAULT,
          }
        );
      },
    });
  }

  // ───────────────────────────────────────────────────────────
  // 11. DIVIDER — animate width on scroll
  // ───────────────────────────────────────────────────────────
  function initDividers() {
    gsap.utils.toArray(".divider").forEach((div) => {
      gsap.fromTo(
        div,
        { scaleX: 0, transformOrigin: "left center" },
        {
          scaleX: 1,
          duration: 1.2,
          ease: EASE_DEFAULT,
          scrollTrigger: {
            trigger: div,
            start: "top 90%",
            once: true,
          },
        }
      );
    });
  }

  // ───────────────────────────────────────────────────────────
  // 12. FOOTER — subtle fade up
  // ───────────────────────────────────────────────────────────
  function initFooter() {
    const footer = document.querySelector("footer");
    if (!footer) return;

    gsap.fromTo(
      footer,
      { opacity: 0, y: 20 },
      {
        opacity: 1,
        y: 0,
        duration: 0.8,
        ease: EASE_DEFAULT,
        scrollTrigger: {
          trigger: footer,
          start: "top 95%",
          once: true,
        },
      }
    );
  }

  // ───────────────────────────────────────────────────────────
  // INIT — wait for DOM, then orchestrate
  // ───────────────────────────────────────────────────────────
  function init() {
    // Disable CSS transition-based reveals since GSAP handles them now
    document.querySelectorAll("[data-reveal]").forEach((el) => {
      el.style.transition = "none";
    });

    initCursorGlow();
    initNav();
    initScrollReveals();
    initMarquee();
    initFeatureCards();
    initArchLayers();
    initSmoothScroll();
    initFeatureGridReveal();
    initOSSCard();
    initCTA();
    initDividers();
    initFooter();

    // Refresh ScrollTrigger after everything is laid out
    ScrollTrigger.refresh();
  }

  // Start when DOM is ready
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    // Small delay to let fonts/images settle layout
    requestAnimationFrame(() => requestAnimationFrame(init));
  }
})();
