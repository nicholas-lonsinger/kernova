// dragspy — guest-side observer for the drag-out mouse-up spike.
// Run in the guest: osascript -l JavaScript /tmp/dragspy.js
// Prints one line per transition of the guest's left-button state, each new
// drag (drag pasteboard change), and the pointer reaching or leaving a screen
// edge. Lines are also written to /tmp/dragspy.log.
ObjC.import('AppKit');

function run(argv) {
  const selftest = argv.length > 0 && argv[0] === '--selftest';
  const logPath = '/tmp/dragspy.log';
  const lines = [];

  function clock() {
    const d = new Date();
    const p = (n, w) => String(n).padStart(w, '0');
    return p(d.getHours(), 2) + ':' + p(d.getMinutes(), 2) + ':' + p(d.getSeconds(), 2) + '.' + p(d.getMilliseconds(), 3);
  }
  function where() {
    const p = $.NSEvent.mouseLocation;
    return Math.round(p.x) + ',' + Math.round(p.y);
  }
  function out(s) {
    const line = clock() + '  ' + s;
    console.log(line);
    lines.push(line);
    if (!selftest) {
      $(lines.join('\n') + '\n').writeToFileAtomicallyEncodingError(logPath, true, $.NSUTF8StringEncoding, null);
    }
  }

  const size = $.NSScreen.mainScreen.frame.size;
  const W = size.width, H = size.height;
  const dragPB = $.NSPasteboard.pasteboardWithName('Apple CFPasteboard drag');

  // A file outside the TCC-protected folders to drag, shown selected in Finder.
  const target = '/tmp/drag-me.txt';
  if (!selftest) {
    $('drag-out spike test file\n').writeToFileAtomicallyEncodingError(target, true, $.NSUTF8StringEncoding, null);
    $.NSWorkspace.sharedWorkspace.activateFileViewerSelectingURLs($([$.NSURL.fileURLWithPath(target)]));
  }

  let buttons = $.NSEvent.pressedMouseButtons;
  let dragCount = dragPB.changeCount;
  let atEdge = false;
  out('dragspy start  screen ' + W + 'x' + H + '  LEFT ' + ((buttons & 1) ? 'DOWN' : 'UP') + '  at ' + where());
  if (selftest) { return; }

  while (true) {
    const b = $.NSEvent.pressedMouseButtons;
    if ((b & 1) !== (buttons & 1)) {
      out(((b & 1) ? 'LEFT DOWN' : 'LEFT UP  ') + '  at ' + where());
    }
    buttons = b;

    const c = dragPB.changeCount;
    if (c !== dragCount) {
      dragCount = c;
      out('DRAG STARTED (drag pasteboard changed)  at ' + where());
    }

    const p = $.NSEvent.mouseLocation;
    const edge = p.x <= 0.5 || p.x >= W - 1.5 || p.y <= 0.5 || p.y >= H - 1.5;
    if (edge !== atEdge) {
      atEdge = edge;
      out((edge ? 'AT SCREEN EDGE' : 'off edge') + '  at ' + where());
    }
    delay(0.01);
  }
}
