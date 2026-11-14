"use server";
import {requireAdmin,flash,str} from "@/lib/admin";
const back="/workspace-7f3c9a2e/google";
export async function saveGoogle(fd:FormData){
 const {sb}=await requireAdmin(true);
 const patch:Record<string,unknown>={web_enabled:fd.get("web_enabled")==="on",app_enabled:fd.get("app_enabled")==="on",web_method:str(fd,"web_method")==="gtm"?"gtm":"direct",conversion_id:str(fd,"conversion_id").trim(),download_label:str(fd,"download_label").trim(),gtm_id:str(fd,"gtm_id").trim(),ads_customer_id:str(fd,"ads_customer_id").replace(/[\s-]/g,""),play_url:str(fd,"play_url"),accounts_linked:fd.get("accounts_linked")==="on",conversions_imported:fd.get("conversions_imported")==="on",test_mode:fd.get("test_mode")==="on"};
 if(patch.conversion_id&&!/^AW-\d{5,20}$/.test(String(patch.conversion_id)))flash(back,{message:"Conversion ID must look like AW-123456789. Paste the ID only."},"");
 if(patch.download_label&&!/^[A-Za-z0-9_-]{1,100}$/.test(String(patch.download_label)))flash(back,{message:"Paste the conversion label only, without scripts or quotes."},"");
 if(patch.gtm_id&&!/^GTM-[A-Z0-9]{4,20}$/.test(String(patch.gtm_id)))flash(back,{message:"GTM Container ID must look like GTM-ABC123. Do not paste HTML code."},"");
 if(patch.web_enabled&&(patch.web_method==="gtm"?!patch.gtm_id:!patch.conversion_id||!patch.download_label))flash(back,{message:"Complete the website setup fields before enabling website tracking."},"");
 if(patch.ads_customer_id&&!/^\d{10}$/.test(String(patch.ads_customer_id)))flash(back,{message:"Google Ads Customer ID contains 10 digits."},"");
 if(patch.play_url&&patch.play_url!=="https://play.google.com/store/apps/details?id=com.pufflecloud.app")flash(back,{message:"Use Puffle's Play listing: https://play.google.com/store/apps/details?id=com.pufflecloud.app"},"");
 const file=fd.get("firebase_config");
 if(file instanceof File&&file.size){
  if(file.size>100000)flash(back,{message:"Select the small google-services.json file downloaded from Firebase."},"");
  try{
   const j=JSON.parse(await file.text());
   const client=j.client?.find((x:{client_info?:{android_client_info?:{package_name?:string}}})=>x.client_info?.android_client_info?.package_name==="com.pufflecloud.app");
   const app=String(client?.client_info?.mobilesdk_app_id??""),project=String(j.project_info?.project_id??""),key=String(client?.api_key?.[0]?.current_key??""),sender=String(j.project_info?.project_number??"");
   if(!/^1:\d+:android:[a-f0-9]+$/i.test(app)||!/^[a-z][a-z0-9-]{4,62}$/.test(project)||!/^AIza[A-Za-z0-9_-]{20,80}$/.test(key)||!/^\d+$/.test(sender))throw Error();
   Object.assign(patch,{firebase_app_id:app,firebase_project_id:project,firebase_api_key:key,firebase_sender_id:sender});
  }catch{flash(back,{message:"This is not a valid Firebase Android configuration for com.pufflecloud.app. Download google-services.json from the Android app in your Firebase project. Service-account private keys are not accepted."},"");}
 }
 const secret=str(fd,"api_secret");if(secret){if(!/^[A-Za-z0-9_-]{10,200}$/.test(secret))flash(back,{message:"Paste the Measurement Protocol API secret only."},"");patch.api_secret=secret;}
 if(fd.get("clear_secret")==="on")patch.api_secret="";
 const {data:old}=await sb.from("google_settings").select("firebase_app_id,api_secret").eq("id",1).single();
 if(patch.app_enabled&&(!(patch.firebase_app_id||old?.firebase_app_id)||!(patch.api_secret??old?.api_secret)))flash(back,{message:"Import the Firebase Android file and add the API secret before enabling Android measurement."},"");
 const {error}=await sb.from("google_settings").update(patch).eq("id",1);
 flash(back,error,"Settings saved. Website changes apply within a minute. Android events require the new app and each user's Google measurement permission. Check Firebase and Google Ads before starting a campaign.");
}
export async function googleAction(fd:FormData){
 const {sb}=await requireAdmin(true);const action=str(fd,"action")==="validate"?"validate":"flush";
 const {data,error}=await sb.functions.invoke("google-send",{body:{action}});
 if(error)flash(back,{message:"Could not run the check. Review the saved setup and try again."},"");
 if(data?.error||data?.ok===false)flash(back,{message:String(data.error??data.message)},"");
 flash(back,null,action==="validate"?"Payload structure validated. Google's validation endpoint does not verify your app ID or API secret; confirm real events in Firebase and imported conversions in Google Ads.":`Submitted ${data?.submitted??0}; test-validated ${data?.validated??0}; failed ${data?.failed??0}; suppressed ${data?.suppressed??0}. HTTP submission is not proof of reporting or ad attribution.`);
}
