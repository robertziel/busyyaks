// Which mascot scene a failure shows (card 672): a 404 is a missing thing (lost), a read that never reached the server
// (status 0: network error, offline) is the cord pulled (offline), anything else the server answered is broken.
import type { MascotScene } from "../components/Mascot";

export function sceneFor(status: number): MascotScene {
  if (status === 404) return "lost";
  if (status === 0) return "offline";
  return "broken";
}

// the down banner's words: the browser's own offline flag says whether it is this device's internet or the server
export function downText(online: boolean, everyS: number): { title: string; detail: string } {
  return online
    ? { title: "busyyaks is not answering", detail: `This page is not live. Retrying every ${everyS} s.` }
    : { title: "No internet", detail: `This device is offline — this page is not live. Retrying every ${everyS} s.` };
}
