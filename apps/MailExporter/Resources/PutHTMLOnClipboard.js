ObjC.import("AppKit");
ObjC.import("Foundation");

/** Put HTML on the general pasteboard as public.html only.
 *  argv: htmlPath
 *  Do not attach RTF — Mail prefers it and splits/renumbers lists.
 */
function run(argv) {
  if (!argv || argv.length < 1) {
    throw new Error("html path required");
  }
  var htmlPath = argv[0];
  var html = $.NSString.stringWithContentsOfFileEncodingError(
    htmlPath,
    $.NSUTF8StringEncoding,
    null
  );
  if (!html) {
    throw new Error("could not read HTML");
  }
  var pb = $.NSPasteboard.generalPasteboard;
  pb.clearContents;
  pb.setStringForType(html, "public.html");
  return "ok";
}
