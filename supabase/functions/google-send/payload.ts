export type Purchase={order_id:string;app_instance_id:string;session_id?:number|null;created_at:string;amount_paise:number;plan_name:string;};
export function purchasePayload(p:Purchase,now=Date.now()){
 if(!/^[a-f0-9]{32}$/i.test(p.app_instance_id))throw Error('Missing genuine Firebase app instance');
 if(!/^[a-f0-9-]{36}$/i.test(p.order_id)||!Number.isSafeInteger(p.amount_paise)||p.amount_paise<=0)throw Error('Invalid verified order');
 const at=new Date(p.created_at).getTime();if(!Number.isFinite(at)||at<now-72*3600000||at>now+60000)throw Error('Purchase is outside delivery window');
 return {app_instance_id:p.app_instance_id,timestamp_micros:at*1000,consent:{ad_user_data:'GRANTED',ad_personalization:'DENIED'},events:[{name:'purchase',params:{transaction_id:p.order_id,currency:'INR',value:p.amount_paise/100,engagement_time_msec:1,...(p.session_id?{session_id:p.session_id}:{}),items:[{item_id:'premium_plan',item_name:p.plan_name.slice(0,100),price:p.amount_paise/100,quantity:1}]}}]};
}
