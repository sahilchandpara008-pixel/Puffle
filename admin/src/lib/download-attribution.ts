/** Shared by server-rendered campaign buttons and browser navigation. */
export function isPaidDownloadQuery(q:URLSearchParams){
 const paid=/^(cpc|ppc|paid|paid_social|paid_search|display|video)$/i.test(q.get("utm_medium")??"");
 const provider=/^(meta|facebook|instagram|ig|fb|google|google_ads)$/i.test(q.get("utm_source")??"");
 return !!(q.get("fbclid")||q.get("gclid")||q.get("gbraid")||q.get("wbraid")||(provider&&paid));
}

