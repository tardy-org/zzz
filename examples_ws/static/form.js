

// ui helpers
function ui_add(item){
  var el = document.createElement("div");
  el.id = "ftp-" + item.uid;
  el.innerHTML = `<div style="border:1px solid #ccc;margin:5px;padding:5px;">
<strong>${item.name}</strong>
<span id="ftp-st-${item.uid}">Waiting...</span>
<progress id="ftp-pg-${item.uid}" value="0" max="${item.total}" style="width:100%"></progress>
<button id="ftp-ps-${item.uid}" onclick="ftp.stop('${item.uid}')">Pause</button>
<button id="ftp-rs-${item.uid}" onclick="ftp.resume('${item.uid}')">Resume</button>
</div>`;
  document.getElementById(item.status_block_id).appendChild(el);
}

function ui_update(item, txt, is_done){
  var pg = document.getElementById("ftp-pg-" + item.uid);
  var st = document.getElementById("ftp-st-" + item.uid);
  if(pg) pg.value = item.offset;
  if(st){
    var pct = Math.round((item.offset / item.total) * 100);
    st.innerHTML = txt || (pct + "% (" + item.offset + " / " + item.total + " bytes)");
  }
  if(is_done){
    var ps = document.getElementById("ftp-ps-" + item.uid);
    if(ps) ps.remove();
    var rs = document.getElementById("ftp-rs-" + item.uid);
    if(rs) rs.remove();
  }
}


// work with form files
function selectFiles(input){
  ftp.autostart = true;
  for(var i = 0; i < input.files.length; i++){
    //ftp.init(input.files[i], ui_add, ui_update);
    var file = input.files[i];
    
    var existing = ftp.queue.find(item =>
      item.status === 'missing_file' &&
      item.name === file.name &&
      item.total === file.size
    );
    
    if(existing){ // resume
      console.log("Restoring file: ", file.name);
      existing.file = file;
      existing.status = 'init';
      existing.autostart = true;
      
      saveState();
      ftp.start(existing.id);
    }else{ // new file
      ftp.init(file, ui_add, ui_update);
    }
  }
  input.value = ''; // clear
}


// lets connect ws
window.addEventListener("load", function(){
  connect();
  restoreState();
}, false);

