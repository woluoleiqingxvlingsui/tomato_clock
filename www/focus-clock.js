/* 专注使用连续时间轴；日历校时不改变已经计量的时长。 */
(function(root){
  "use strict";
  const DRIFT_MS=2000;
  function validSample(s){
    return s&&typeof s.source==="string"&&typeof s.epoch==="string"
      &&Number.isFinite(s.monoMs)&&Number.isFinite(s.wallMs);
  }
  function create(startTs,s){
    if(!validSample(s))throw new Error("invalid clock sample");
    return {v:1,source:s.source,epoch:s.epoch,monoAt:s.monoMs,wallAt:s.wallMs,
      logicalAt:startTs,adjusted:false,uncertain:false};
  }
  function valid(c){
    return c&&c.v===1&&typeof c.source==="string"&&typeof c.epoch==="string"
      &&[c.monoAt,c.wallAt,c.logicalAt].every(Number.isFinite);
  }
  function now(sess,s){
    if(!validSample(s))throw new Error("invalid clock sample");
    if(!valid(sess.clock))sess.clock=create(Math.max(sess.startTs,s.wallMs),s);
    const c=sess.clock,delta=s.monoMs-c.monoAt;
    if(c.source===s.source&&c.epoch===s.epoch&&delta>=0){
      if(Math.abs(s.wallMs-c.wallAt-delta)>DRIFT_MS)c.adjusted=true;
      return Math.round(c.logicalAt+delta);
    }
    // 重启/计时源改变后，墙钟只能提供估算；保留会话并要求核对。
    const estimate=c.logicalAt+Math.max(0,s.wallMs-c.wallAt);
    sess.clock=Object.assign(create(estimate,s),{adjusted:c.adjusted,uncertain:true});
    return Math.round(estimate);
  }
  function checkpoint(sess,s){
    const logical=now(sess,s),c=sess.clock;
    c.logicalAt=logical;c.monoAt=s.monoMs;c.wallAt=s.wallMs;
    return logical;
  }
  function elapsed(sess,s){
    const t=now(sess,s);
    return Math.max(0,(sess.pausedAt||t)-sess.startTs-(sess.pausedAccumMs||0));
  }
  const api={create,valid,now,checkpoint,elapsed,DRIFT_MS};
  root.FocusClock=api;
  if(typeof module!=="undefined"&&module.exports)module.exports=api;
})(typeof globalThis!=="undefined"?globalThis:this);
