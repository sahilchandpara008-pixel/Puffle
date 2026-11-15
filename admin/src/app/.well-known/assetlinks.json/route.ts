import { NextResponse } from "next/server";

export const dynamic = "force-dynamic";

export function GET() {
  const fps = (process.env.ANDROID_SIGNING_SHA256 || "B7:0A:41:56:E6:23:81:D3:3E:43:0D:AB:ED:74:62:52:3D:D6:06:7F:F7:76:B6:7A:55:E8:E0:26:C7:01:81:0C").split(",").map((s) => s.trim()).filter(Boolean);
  const body = ["com.pufflecloud.app"].map((pkg) => ({
    relation: ["delegate_permission/common.handle_all_urls"],
    target: { namespace: "android_app", package_name: pkg, sha256_cert_fingerprints: fps },
  }));
  return NextResponse.json(body);
}
