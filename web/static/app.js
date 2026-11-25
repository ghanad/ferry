'use strict';

(() => {
  const page = document.body.dataset.page;
  const csrf = document.querySelector('meta[name="csrf-token"]')?.content || '';
  const CHUNK_SIZE = 8 * 1024 * 1024;

  class ApiError extends Error {
    constructor(message, status, data) {
      super(message);
      this.name = 'ApiError';
      this.status = status;
      this.data = data;
    }
  }

  async function api(url, options = {}) {
    const { json, ...fetchOptions } = options;
    const headers = new Headers(fetchOptions.headers || {});
    headers.set('X-Requested-With', 'Ferry');
    headers.set('X-CSRF-Token', csrf);
    let body = fetchOptions.body;
    if (json !== undefined) {
      headers.set('Content-Type', 'application/json');
      body = JSON.stringify(json);
    }
    let response;
    try {
      response = await fetch(url, {
        ...fetchOptions,
        body,
        headers,
        credentials: 'same-origin',
      });
    } catch {
      throw new ApiError('Could not reach Ferry. Check your connection and try again.', 0, null);
    }
    let data = null;
    const type = response.headers.get('content-type') || '';
    if (type.includes('application/json')) {
      try {
        data = await response.json();
      } catch {
        data = null;
      }
    }
    if (!response.ok) {
      if (response.status === 401) {
        window.location.assign('/login');
      }
      throw new ApiError(
        (data && data.error) || `Request failed (HTTP ${response.status}).`,
        response.status,
        data
      );
    }
    return data;
  }

  function formatBytes(bytes) {
    const n = Number(bytes) || 0;
    if (n < 0) return '0 B';
    const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'];
    if (n < 1024) return `${n} B`;
    let value = n;
    let unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit += 1;
    }
    return `${value.toFixed(value >= 100 ? 0 : 1)} ${units[unit]}`;
  }

  function sleep(ms) {
    return new Promise((resolve) => window.setTimeout(resolve, ms));
  }

  function showError(message) {
    const el = document.getElementById('page-error');
    if (!el) return;
    el.textContent = message || 'Something went wrong.';
    el.hidden = false;
  }

  function clearError() {
    const el = document.getElementById('page-error');
    if (!el) return;
    el.hidden = true;
    el.textContent = '';
  }

  async function copyText(text, button) {
    let ok = false;
    try {
      await navigator.clipboard.writeText(text);
      ok = true;
    } catch {
      const area = document.createElement('textarea');
      area.value = text;
      area.setAttribute('readonly', '');
      area.className = 'visually-hidden';
      document.body.appendChild(area);
      area.select();
      try {
        ok = document.execCommand('copy');
      } catch {
        ok = false;
      }
      area.remove();
    }
    if (button) {
      const old = button.textContent;
      button.textContent = ok ? 'Copied!' : 'Copy failed';
      window.setTimeout(() => { button.textContent = old; }, 1600);
    }
    if (!ok) showError('Copying to the clipboard was blocked by the browser. Select the text and copy it manually.');
  }

  function setBusy(button, busy) {
    if (!button) return;
    button.disabled = busy;
    button.setAttribute('aria-busy', busy ? 'true' : 'false');
  }

  function bindCancelButtons() {
    document.querySelectorAll('.js-cancel-job').forEach((button) => {
      if (button.dataset.bound === 'true') return;
      button.dataset.bound = 'true';
      button.addEventListener('click', async () => {
        const id = button.dataset.jobId;
        if (!id) return;
        if (!window.confirm('Cancel this transfer? Temporary files will be deleted.')) return;
        clearError();
        setBusy(button, true);
        try {
          await api(`/api/jobs/${encodeURIComponent(id)}/cancel`, { method: 'POST' });
          window.location.reload();
        } catch (err) {
          showError(err.message);
          setBusy(button, false);
        }
      });
    });
  }

  function initIndex() {
    bindCancelButtons();
    const button = document.getElementById('new-transfer');
    if (!button) return;
    button.addEventListener('click', async () => {
      clearError();
      setBusy(button, true);
      try {
        const data = await api('/api/jobs', { method: 'POST' });
        window.location.assign(`/jobs/${encodeURIComponent(data.id)}`);
      } catch (err) {
        showError(err.message);
        setBusy(button, false);
      }
    });
  }

  function initHistory() {
    bindCancelButtons();
    document.querySelectorAll('.js-delete-image').forEach((button) => {
      button.addEventListener('click', async () => {
        const id = button.dataset.jobId;
        if (!id) return;
        if (!window.confirm('Delete this image tag from Docker Hub? The history record will stay.')) return;
        clearError();
        setBusy(button, true);
        try {
          await api(`/api/jobs/${encodeURIComponent(id)}/image-delete`, { method: 'POST' });
          window.location.reload();
        } catch (err) {
          showError(err.message);
          setBusy(button, false);
        }
      });
    });

    document.querySelectorAll('.js-delete-record').forEach((button) => {
      button.addEventListener('click', async () => {
        const id = button.dataset.jobId;
        if (!id) return;
        if (!window.confirm('Delete this history record? Any Docker Hub image tag is NOT deleted by this action.')) return;
        clearError();
        setBusy(button, true);
        try {
          await api(`/api/jobs/${encodeURIComponent(id)}`, { method: 'DELETE' });
          window.location.reload();
        } catch (err) {
          showError(err.message);
          setBusy(button, false);
        }
      });
    });

    const purgeForm = document.getElementById('purge-form');
    if (purgeForm) {
      purgeForm.addEventListener('submit', async (event) => {
        event.preventDefault();
        const daysInput = document.getElementById('purge-days');
        const days = Number.parseInt(daysInput?.value || '', 10);
        if (!Number.isInteger(days) || days < 1) {
          showError('Enter a number of days of at least 1.');
          return;
        }
        if (!window.confirm(`Delete every Docker Hub image older than ${days} day(s)? History records stay.`)) return;
        clearError();
        const button = purgeForm.querySelector('button');
        setBusy(button, true);
        try {
          const result = await api('/api/history/purge-images', { method: 'POST', json: { days } });
          if (result.failures && result.failures.length) {
            showError(`Deleted ${result.deleted} image(s). Some failed:\n${result.failures.join('\n')}`);
            setBusy(button, false);
          } else {
            window.location.reload();
          }
        } catch (err) {
          showError(err.message);
          setBusy(button, false);
        }
      });
    }
  }

  function initJob() {
    const jobId = document.body.dataset.jobId;
    if (!jobId) return;
    const maxBytes = Number(document.body.dataset.maxBytes) || 0;

    const els = {
      state: document.getElementById('job-state'),
      draft: document.getElementById('draft-panel'),
      run: document.getElementById('run-panel'),
      done: document.getElementById('done-panel'),
      failed: document.getElementById('failed-panel'),
      runState: document.getElementById('run-state'),
      progress: document.getElementById('job-progress'),
      percent: document.getElementById('progress-percent'),
      progressText: document.getElementById('progress-text'),
      log: document.getElementById('job-log'),
      doneLog: document.getElementById('done-log'),
      failedLog: document.getElementById('failed-log'),
      failure: document.getElementById('failure-message'),
      image: document.getElementById('image-name'),
      imageDeleted: document.getElementById('image-deleted-note'),
      commands: document.getElementById('pull-commands'),
      copyImage: document.getElementById('copy-image'),
      copyCommands: document.getElementById('copy-commands'),
      totalText: document.getElementById('total-text'),
      totalProgress: document.getElementById('total-progress'),
      uploadList: document.getElementById('upload-list'),
      entryList: document.getElementById('entry-list'),
      start: document.getElementById('start-button'),
      startHint: document.getElementById('start-hint'),
      fileInput: document.getElementById('file-input'),
      dropzone: document.getElementById('dropzone'),
      urlForm: document.getElementById('url-form'),
      urlInput: document.getElementById('url-input'),
      cancel: document.getElementById('cancel-button'),
      passphrase: document.getElementById('passphrase'),
      passphraseConfirm: document.getElementById('passphrase-confirm'),
      clearPassphrase: document.getElementById('clear-passphrase'),
      clearPassphraseRow: document.getElementById('clear-passphrase-row'),
      compress: document.getElementById('compress'),
      optionsState: document.getElementById('options-state'),
      runOptions: document.getElementById('run-options'),
    };

    const base = `/api/jobs/${encodeURIComponent(jobId)}`;
    let latest = null;
    let active = null;
    let uploading = false;
    let polling = false;
    let sameOffsetRetries = 0;
    let pendingResume = null;
    let pollTimer = null;
    let draftSignature = '';
    let optionsInitialized = false;

    els.copyImage?.addEventListener('click', () => copyText((latest && latest.image) || '', els.copyImage));

    els.cancel?.addEventListener('click', async () => {
      if (!window.confirm('Cancel this transfer? Temporary files will be deleted.')) return;
      clearError();
      setBusy(els.cancel, true);
      try {
        await api(`${base}/cancel`, { method: 'POST' });
        await refresh();
      } catch (err) {
        showError(err.message);
        setBusy(els.cancel, false);
      }
    });
    els.copyCommands?.addEventListener('click', () => copyText(els.commands?.textContent || '', els.copyCommands));

    function terminal(state) {
      return state === 'done' || state === 'failed';
    }

    function render(data) {
      if (!data) return;
      latest = data;
      els.state.textContent = data.state;
      els.state.className = `badge badge-${data.state}`;
      els.draft.hidden = data.state !== 'draft';
      els.run.hidden = !['queued', 'downloading', 'building', 'pushing'].includes(data.state);
      els.done.hidden = data.state !== 'done';
      els.failed.hidden = data.state !== 'failed';
      if (data.state === 'draft') renderDraft(data);
      if (data.state !== 'draft' && els.runOptions) {
        const parts = [];
        if (data.compress) parts.push('gzip compression');
        if (data.encrypted) parts.push('passphrase encryption');
        els.runOptions.hidden = parts.length === 0;
        els.runOptions.textContent = parts.length ? `File options: ${parts.join(' + ')}.` : '';
      }
      if (!['queued', 'downloading', 'building', 'pushing'].includes(data.state) && els.run.hidden === false) {
        els.run.hidden = true;
      }
      if (['queued', 'downloading', 'building', 'pushing'].includes(data.state)) {
        renderRun(data);
        if (els.cancel) {
          els.cancel.disabled = !data.can_cancel || data.progress?.text === 'Cancelling...';
        }
      }
      if (data.state === 'done') renderDone(data);
      if (data.state === 'failed') {
        els.failure.textContent = data.error || 'The worker reported an error. Check the log below.';
        setLog(els.failedLog, data.log);
      }
    }

    function renderDraft(data) {
      const total = Number(data.total_bytes) || 0;
      els.totalText.textContent = `${formatBytes(total)} / ${formatBytes(maxBytes)}`;
      els.totalProgress.max = maxBytes || 1;
      els.totalProgress.value = Math.min(total, maxBytes || 1);

      const uploads = data.uploads || [];
      const files = data.files || [];
      const signature = JSON.stringify([
        uploads.map((u) => [u.id, u.received, u.size]),
        files.map((f) => [f.id, f.name, f.size, f.status]),
        active ? [active.id, active.received, active.error || ''] : null,
      ]);
      if (signature !== draftSignature) {
        draftSignature = signature;
        els.uploadList.replaceChildren();
        for (const upload of uploads) {
          if (active && active.id === upload.id) continue;
          els.uploadList.appendChild(serverUploadRow(upload));
        }
        if (active) els.uploadList.appendChild(activeUploadRow(active));

        els.entryList.replaceChildren();
        for (const file of files) {
          els.entryList.appendChild(fileRow(file));
        }
        if (!files.length && !uploads.length && !active) {
          const empty = document.createElement('p');
          empty.className = 'muted';
          empty.textContent = 'No files or URLs added yet.';
          els.entryList.appendChild(empty);
        }
      }

      const pending = uploads.length;
      let hint = 'Ready to start.';
      if (active && active.error) hint = 'The last upload failed. Use Resume or Remove.';
      else if (uploading || active) hint = 'Upload in progress. Start is available when it finishes.';
      else if (pending > 0) hint = `${pending} incomplete upload(s). Resume by choosing the same file again, or remove them.`;
      else if (!files.length) hint = 'Add at least one file or URL.';
      else if (total > maxBytes) hint = 'The job is over the size limit. Remove something before starting.';
      els.startHint.textContent = hint;
      els.start.disabled = uploading || !!active || !data.can_start;
      if (!optionsInitialized && els.compress) {
        els.compress.checked = !!data.compress;
        optionsInitialized = true;
      }
      if (els.clearPassphraseRow) {
        els.clearPassphraseRow.hidden = !data.has_passphrase;
        if (!data.has_passphrase && els.clearPassphrase) els.clearPassphrase.checked = false;
      }
      if (els.optionsState) {
        const saved = [];
        if (data.compress) saved.push('compression on');
        if (data.has_passphrase) saved.push('a passphrase is saved');
        els.optionsState.textContent = saved.length ? `Saved: ${saved.join(', ')}. Leave the passphrase empty to keep it.` : '';
      }
      els.start.setAttribute('aria-busy', uploading ? 'true' : 'false');
    }

    function serverUploadRow(upload) {
      const row = document.createElement('div');
      row.className = 'entry';
      const main = document.createElement('div');
      main.className = 'entry-main';
      const name = document.createElement('div');
      name.className = 'entry-name';
      name.textContent = upload.filename;
      const meta = document.createElement('div');
      meta.className = 'entry-meta';
      meta.textContent = `${formatBytes(upload.received)} of ${formatBytes(upload.size)} received · incomplete`;
      main.append(name, meta);
      const actions = document.createElement('div');
      actions.className = 'entry-actions';
      const resume = document.createElement('button');
      resume.type = 'button';
      resume.className = 'button button-small';
      resume.textContent = 'Resume';
      resume.addEventListener('click', () => {
        pendingResume = upload;
        els.fileInput.click();
      });
      const remove = document.createElement('button');
      remove.type = 'button';
      remove.className = 'button button-small button-quiet';
      remove.textContent = 'Remove';
      remove.addEventListener('click', async () => {
        if (!window.confirm(`Remove the incomplete upload "${upload.filename}"?`)) return;
        setBusy(remove, true);
        try {
          await api(`${base}/uploads/${encodeURIComponent(upload.id)}`, { method: 'DELETE' });
          await refresh();
        } catch (err) {
          showError(err.message);
          setBusy(remove, false);
        }
      });
      actions.append(resume, remove);
      row.append(main, actions);
      return row;
    }

    function activeUploadRow(upload) {
      const row = document.createElement('div');
      row.className = 'entry';
      const main = document.createElement('div');
      main.className = 'entry-main';
      const name = document.createElement('div');
      name.className = 'entry-name';
      name.textContent = upload.filename;
      const meta = document.createElement('div');
      meta.className = 'entry-meta';
      const percent = upload.size > 0 ? Math.min(100, Math.floor((upload.received / upload.size) * 100)) : 100;
      meta.textContent = `${formatBytes(upload.received)} of ${formatBytes(upload.size)} · ${percent}%`;
      const progress = document.createElement('progress');
      progress.max = upload.size || 1;
      progress.value = Math.min(upload.received, upload.size || 1);
      progress.setAttribute('aria-label', `Upload progress for ${upload.filename}`);
      main.append(name, meta, progress);
      if (upload.error) {
        const err = document.createElement('div');
        err.className = 'entry-error';
        err.textContent = upload.error;
        main.appendChild(err);
      }
      const actions = document.createElement('div');
      actions.className = 'entry-actions';
      if (upload.error && upload.file) {
        const resume = document.createElement('button');
        resume.type = 'button';
        resume.className = 'button button-small';
        resume.textContent = 'Resume';
        resume.addEventListener('click', () => resumeUpload(upload));
        actions.appendChild(resume);
      }
      const remove = document.createElement('button');
      remove.type = 'button';
      remove.className = 'button button-small button-quiet';
      remove.textContent = 'Remove';
      remove.disabled = uploading;
      remove.addEventListener('click', async () => {
        if (!window.confirm(`Remove the incomplete upload "${upload.filename}"?`)) return;
        setBusy(remove, true);
        try {
          await api(`${base}/uploads/${encodeURIComponent(upload.id)}`, { method: 'DELETE' });
          active = null;
          await refresh();
        } catch (err) {
          showError(err.message);
          setBusy(remove, false);
        }
      });
      actions.appendChild(remove);
      row.append(main, actions);
      return row;
    }

    function fileRow(file) {
      const row = document.createElement('div');
      row.className = 'entry';
      const main = document.createElement('div');
      main.className = 'entry-main';
      const name = document.createElement('div');
      name.className = 'entry-name';
      name.textContent = file.status === 'done' ? file.name : file.url;
      const meta = document.createElement('div');
      meta.className = 'entry-meta';
      if (file.status === 'done') {
        meta.textContent = `${file.source === 'url' ? 'Downloaded URL' : 'Uploaded file'} · ${formatBytes(file.size)}`;
        if (file.sha256) meta.textContent += ` · sha256 ${file.sha256.slice(0, 16)}…`;
        if (file.md5) meta.textContent += ` · md5 ${file.md5}`;
      } else {
        meta.textContent = 'Download link · downloaded when the transfer starts';
      }
      main.append(name, meta);
      const actions = document.createElement('div');
      actions.className = 'entry-actions';
      const remove = document.createElement('button');
      remove.type = 'button';
      remove.className = 'button button-small button-quiet';
      remove.textContent = 'Remove';
      remove.addEventListener('click', async () => {
        if (!window.confirm('Remove this entry from the transfer?')) return;
        setBusy(remove, true);
        try {
          await api(`${base}/files/${encodeURIComponent(file.id)}`, { method: 'DELETE' });
          await refresh();
        } catch (err) {
          showError(err.message);
          setBusy(remove, false);
        }
      });
      actions.appendChild(remove);
      row.append(main, actions);
      return row;
    }

    function renderRun(data) {
      els.runState.textContent = data.progress?.text || data.state;
      const progress = data.progress || { done: 0, total: 0, text: '' };
      els.progress.removeAttribute('value');
      if (progress.total > 0) {
        els.progress.max = progress.total;
        els.progress.value = Math.min(progress.done || 0, progress.total);
        const pct = Math.min(100, Math.floor(((progress.done || 0) / progress.total) * 100));
        els.percent.textContent = `${pct}% · ${formatBytes(progress.done || 0)} / ${formatBytes(progress.total)}`;
      } else if (progress.done > 0) {
        els.progress.removeAttribute('value');
        els.percent.textContent = formatBytes(progress.done);
      } else {
        els.percent.textContent = '';
      }
      els.progressText.textContent = progress.text || `State: ${data.state}`;
      setLog(els.log, data.log);
    }

    function renderDone(data) {
      els.image.textContent = data.image || '—';
      els.imageDeleted.hidden = !data.image_deleted;
      const image = data.image || '<image>';
      const lines = [
        'docker login',
        `docker pull ${image}`,
        `docker create --name ferry-tmp ${image}`,
        'docker cp ferry-tmp:/data ./ferry-files',
        'docker rm ferry-tmp',
      ];
      if (data.encrypted || data.compress) {
        lines.push(`docker run --rm -it -v "$PWD/ferry-files:/work" --entrypoint /data/ferry ${image} unpack --dir /work`);
      }
      lines.push('cd ferry-files');
      lines.push('sha256sum -c SHA256SUMS');
      els.commands.textContent = lines.join('\n');
      setLog(els.doneLog, data.log);
    }

    function setLog(element, text) {
      if (!element) return;
      const nearBottom = element.scrollTop + element.clientHeight >= element.scrollHeight - 40;
      element.textContent = text && text.trim() ? text : 'Waiting…';
      if (nearBottom) element.scrollTop = element.scrollHeight;
    }

    async function refresh() {
      const data = await api(base, { method: 'GET' });
      render(data);
      return data;
    }

    async function uploadFiles(fileList) {
      if (uploading) return;
      const files = Array.from(fileList || []);
      if (!files.length) return;

      if (pendingResume) {
        const upload = pendingResume;
        pendingResume = null;
        const wanted = upload.original_filename || upload.filename;
        const match = files.find((f) => f.name === wanted && f.size === upload.size);
        if (!match) {
          showError(`Choose the original file "${wanted}" (${formatBytes(upload.size)}) to resume this upload.`);
          return;
        }
        uploading = true;
        active = { ...upload, file: match, error: '' };
        sameOffsetRetries = 0;
        clearError();
        try {
          await continueUpload();
        } catch (err) {
          if (active) active.error = err.message;
          showError(err.message);
        } finally {
          uploading = false;
          await refresh().catch((err) => showError(err.message));
        }
        return;
      }

      uploading = true;
      clearError();
      let projected = Number(latest && latest.total_bytes) || 0;
      try {
        for (const file of files) {
          if (projected + file.size > maxBytes) {
            showError(`"${file.name}" would exceed the ${formatBytes(maxBytes)} job limit.`);
            continue;
          }
          try {
            sameOffsetRetries = 0;
            const created = await startUpload(file);
            projected += Number(created && created.size) || file.size;
          } catch (err) {
            if (active) active.error = err.message;
            showError(err.message);
          }
        }
      } finally {
        uploading = false;
        await refresh().catch((err) => showError(err.message));
      }
    }

    async function startUpload(file) {
      const created = await api(`${base}/uploads`, {
        method: 'POST',
        json: { filename: file.name, size: file.size },
      });
      active = {
        id: created.upload_id,
        filename: created.filename,
        size: file.size,
        received: 0,
        file,
        error: '',
      };
      if (latest) renderDraft(latest);
      await continueUpload();
      return created;
    }

    async function resumeUpload(upload) {
      if (uploading || !upload.file) return;
      uploading = true;
      active = upload;
      active.error = '';
      sameOffsetRetries = 0;
      clearError();
      try {
        await continueUpload();
      } catch (err) {
        active.error = err.message;
        showError(err.message);
      } finally {
        uploading = false;
        await refresh().catch((err) => showError(err.message));
      }
    }

    async function continueUpload() {
      if (!active) return;
      const upload = active;
      let state;
      try {
        state = await api(`${base}/uploads/${encodeURIComponent(upload.id)}`, { method: 'GET' });
      } catch (err) {
        upload.error = err.message;
        throw err;
      }
      if (state.completed) {
        active = null;
        return;
      }
      upload.received = Number(state.received) || 0;
      if (latest) renderDraft(latest);

      while (upload.received < upload.size) {
        const offset = upload.received;
        const end = Math.min(offset + CHUNK_SIZE, upload.size);
        const blob = upload.file.slice(offset, end);
        let result;
        try {
          result = await putChunkWithRetries(upload.id, offset, blob);
        } catch (err) {
          upload.error = err.message;
          throw err;
        }
        if (result.completed) {
          active = null;
          return;
        }
        if (typeof result.received !== 'number') {
          throw new Error('The server did not return upload progress.');
        }
        if (result.received <= offset) {
          sameOffsetRetries += 1;
          if (sameOffsetRetries > 3) {
            throw new Error('The server did not accept the next chunk. Remove this upload and try again.');
          }
        } else {
          sameOffsetRetries = 0;
        }
        upload.received = result.received;
        if (latest) renderDraft(latest);
      }
      sameOffsetRetries = 0;
      await api(`${base}/uploads/${encodeURIComponent(upload.id)}/complete`, { method: 'POST' });
      active = null;
    }

    async function putChunkWithRetries(uploadId, offset, blob) {
      const url = `${base}/uploads/${encodeURIComponent(uploadId)}?offset=${offset}`;
      let delay = 500;
      for (let attempt = 1; attempt <= 5; attempt += 1) {
        try {
          return await api(url, {
            method: 'PUT',
            body: blob,
            headers: { 'Content-Type': 'application/octet-stream' },
          });
        } catch (err) {
          if (err.status === 409) {
            const received = Number(err.data && err.data.received);
            if (Number.isFinite(received) && received >= 0) {
              return { received, conflict: true };
            }
            throw err;
          }
          const permanent = [400, 401, 403, 404, 413].includes(err.status);
          if (permanent || attempt === 5) throw err;
          await sleep(delay);
          delay *= 2;
          try {
            const state = await api(`${base}/uploads/${encodeURIComponent(uploadId)}`, { method: 'GET' });
            if (state.completed) return { received: state.received, completed: true };
          } catch (stateErr) {
            if ([401, 404].includes(stateErr.status)) throw stateErr;
          }
        }
      }
      throw new Error('Chunk upload failed after five attempts.');
    }

    els.fileInput?.addEventListener('change', () => {
      const files = els.fileInput.files;
      if (!files || files.length === 0) {
        pendingResume = null;
        return;
      }
      uploadFiles(files);
      els.fileInput.value = '';
    });
    els.fileInput?.addEventListener('cancel', () => {
      pendingResume = null;
    });

    if (els.dropzone) {
      ['dragenter', 'dragover'].forEach((eventName) => {
        els.dropzone.addEventListener(eventName, (event) => {
          event.preventDefault();
          els.dropzone.classList.add('is-dragging');
        });
      });
      ['dragleave', 'drop'].forEach((eventName) => {
        els.dropzone.addEventListener(eventName, (event) => {
          event.preventDefault();
          els.dropzone.classList.remove('is-dragging');
        });
      });
      els.dropzone.addEventListener('drop', (event) => {
        if (event.dataTransfer && event.dataTransfer.files.length) {
          uploadFiles(event.dataTransfer.files);
        }
      });
      els.dropzone.addEventListener('keydown', (event) => {
        if (event.key === 'Enter' || event.key === ' ') {
          event.preventDefault();
          els.fileInput.click();
        }
      });
    }

    els.urlForm?.addEventListener('submit', async (event) => {
      event.preventDefault();
      const value = (els.urlInput.value || '').trim();
      if (!value) return;
      clearError();
      const button = els.urlForm.querySelector('button');
      setBusy(button, true);
      try {
        await api(`${base}/urls`, { method: 'POST', json: { url: value } });
        els.urlInput.value = '';
        await refresh();
      } catch (err) {
        showError(err.message);
      } finally {
        setBusy(button, false);
      }
    });

    els.start?.addEventListener('click', async () => {
      clearError();
      setBusy(els.start, true);
      try {
        const passphrase = (els.passphrase && els.passphrase.value) || '';
        const confirm = (els.passphraseConfirm && els.passphraseConfirm.value) || '';
        const clearPassphrase = !!(els.clearPassphrase && els.clearPassphrase.checked);
        if (passphrase && passphrase !== confirm) {
          showError('The passphrase and its confirmation do not match.');
          setBusy(els.start, false);
          return;
        }
        const compress = !!(els.compress && els.compress.checked);
        await api(`${base}/start`, {
          method: 'POST',
          json: { passphrase, compress, clear_passphrase: clearPassphrase },
        });
        await refresh();
        startPolling();
      } catch (err) {
        showError(err.message);
        setBusy(els.start, false);
      }
    });

    const ACTIVE_STATES = ['queued', 'downloading', 'building', 'pushing'];

    function startPolling() {
      if (pollTimer) window.clearTimeout(pollTimer);
      pollTimer = window.setTimeout(poll, 2000);
    }

    async function poll() {
      if (polling) return;
      polling = true;
      try {
        const data = await refresh();
        if (!data || !ACTIVE_STATES.includes(data.state)) {
          polling = false;
          return;
        }
      } catch (err) {
        showError(err.message);
      } finally {
        polling = false;
      }
      pollTimer = window.setTimeout(poll, 2000);
    }

    refresh()
      .then((data) => {
        if (data && ACTIVE_STATES.includes(data.state)) startPolling();
      })
      .catch((err) => showError(err.message));

    window.addEventListener('beforeunload', (event) => {
      if (pollTimer) window.clearTimeout(pollTimer);
      if (uploading) {
        event.preventDefault();
        event.returnValue = '';
      }
    });
  }

  if (page === 'index') initIndex();
  if (page === 'history') initHistory();
  if (page === 'job') initJob();
})();
