import { createEffect, createSignal, onCleanup, onMount } from "solid-js";
import { invoke } from "@tauri-apps/api/core";

type Props = {
  tabId: string;
  active: boolean;
  focus?: boolean;
  cwd?: string | null;
  generation: number;
};

function rectFor(el: HTMLElement) {
  const r = el.getBoundingClientRect();
  return {
    x: r.left,
    y: r.top,
    width: r.width,
    height: r.height,
  };
}

export default function NativeTerminalHost(props: Props) {
  let host!: HTMLDivElement;
  let observer: ResizeObserver | null = null;
  let frameRequest = 0;
  let retryTimer = 0;
  let retryDelay = 16;
  let lastTabId: string | null = null;
  // Plain JS flag — set false in onCleanup. Guards every async callback
  // (invoke .then / setTimeout retry / rAF) so they bail before touching
  // SolidJS reactive props on a disposed component. Reading stale props
  // throws "stale value" and corrupts the reactive graph.
  let isMounted = true;
  const [shown, setShown] = createSignal(false);
  const handleResize = () => sync();

  function clearRetry() {
    if (retryTimer !== 0) {
      window.clearTimeout(retryTimer);
      retryTimer = 0;
    }
  }

  function scheduleRetry(tabId: string, generation: number, focus: boolean) {
    if (!isMounted) return;
    if (!props.active || props.tabId !== tabId || props.generation !== generation) return;
    clearRetry();
    retryTimer = window.setTimeout(() => {
      retryTimer = 0;
      if (!isMounted) return;
      sync(tabId, generation, focus);
    }, retryDelay);
    retryDelay = Math.min(Math.ceil(retryDelay * 1.6), 250);
  }

  function sync(tabId?: string, generation?: number, focus?: boolean) {
    if (!isMounted || !host) return;
    if (!props.active) return;
    // Snapshot prop values at call entry. Reading props inside async
    // callbacks risks stale-value throws if the parent already unmounted.
    const tid = tabId ?? props.tabId;
    const gen = generation ?? props.generation;
    const f = focus ?? props.focus ?? true;
    const cwd = props.cwd ?? null;
    cancelAnimationFrame(frameRequest);
    frameRequest = requestAnimationFrame(() => {
      if (!isMounted) return;
      const rect = rectFor(host);
      if (rect.width < 24 || rect.height < 24) {
        scheduleRetry(tid, gen, f);
        return;
      }
      void invoke<boolean>("terminal_native_show", {
        tabId: tid,
        cwd,
        rect,
        focus: f,
        generation: gen,
      })
        .then((ok) => {
          if (!isMounted) return;
          if (ok) {
            retryDelay = 16;
            clearRetry();
            setShown(true);
          } else {
            scheduleRetry(tid, gen, f);
          }
        })
        .catch((e) => {
          if (!isMounted) return;
          console.error("terminal_native_show failed:", e);
          scheduleRetry(tid, gen, f);
        });
    });
  }

  function hide(tabId = props.tabId, generation = props.generation) {
    clearRetry();
    setShown(false);
    void invoke("terminal_native_hide", { tabId, generation }).catch((e) =>
      console.error("terminal_native_hide failed:", e),
    );
  }

  onMount(() => {
    observer = new ResizeObserver(handleResize);
    observer.observe(host);
    window.addEventListener("resize", handleResize);
    queueMicrotask(sync);
  });

  createEffect(() => {
    const tabId = props.tabId;
    const generation = props.generation;
    const focus = props.focus ?? true;
    if (lastTabId !== null && lastTabId !== tabId) {
      hide(lastTabId, generation);
    }
    lastTabId = tabId;

    if (props.active) {
      retryDelay = 16;
      sync(tabId, generation, focus);
    } else {
      hide(tabId, generation);
    }
  });

  onCleanup(() => {
    isMounted = false;
    cancelAnimationFrame(frameRequest);
    clearRetry();
    observer?.disconnect();
    window.removeEventListener("resize", handleResize);
    // Capture before flagging unmounted? — already false above. But hide
    // doesn't touch reactive props after isMounted=false; it just calls
    // invoke with explicit args.
    const lastGen = props.generation;
    const tabId = lastTabId ?? props.tabId;
    void invoke("terminal_native_hide", { tabId, generation: lastGen }).catch(
      (e) => console.error("terminal_native_hide failed:", e),
    );
  });

  return (
    <div ref={host} class="native-terminal-host" data-ready={shown() ? "true" : "false"}>
      <div class="native-terminal-host__fallback">starting terminal...</div>
    </div>
  );
}
