// ─── Attachments Data API ──────────────────────────────────────
// Supporting documents on requests/responses/internal requests. The
// `attachments` bucket is private — supabase/storage-policies.sql
// composes its access rules on top of the `attachments` table's own
// RLS (attachments_select/_insert/_delete), so this layer just shapes
// requests/responses, same as everywhere else in this app; it isn't
// the real authorization boundary.
//
// Client-side type/size validation only (matches how org-logo upload
// already works in this app — no Edge Function gate). Real enforcement
// of file type/size is a Storage-level limitation, not attempted here.

const AttachmentsAPI = (() => {
  const ALLOWED_EXTENSIONS = ['pdf', 'docx', 'xlsx', 'jpg', 'jpeg', 'png'];
  const MAX_FILE_BYTES = 20 * 1024 * 1024;   // 20 MB
  const MAX_TOTAL_BYTES = 100 * 1024 * 1024; // 100 MB per record

  async function logAudit(recordId, notes) {
    const db = getSupabase();
    const session = await Auth.getSession();
    if (!session) return;
    await db.from('audit_logs').insert({
      user_id: session.user.id,
      action: 'created', record_type: 'attachment', record_id: recordId, notes,
    });
  }

  return {
    ALLOWED_EXTENSIONS, MAX_FILE_BYTES, MAX_TOTAL_BYTES,

    async list(recordType, recordId) {
      const db = getSupabase();
      const { data, error } = await db.from('attachments')
        .select('*, uploaded_by_user:users!attachments_uploaded_by_fkey(full_name)')
        .eq('record_type', recordType).eq('record_id', recordId)
        .order('created_at', { ascending: true });
      if (error) throw error;
      return data;
    },

    // Batched variant of list() above — one query for every record of a
    // given type instead of one query per record; call sites group the
    // flat result by record_id afterward.
    async listForRecords(recordType, recordIds) {
      if (!recordIds || recordIds.length === 0) return [];
      const db = getSupabase();
      const { data, error } = await db.from('attachments')
        .select('*, uploaded_by_user:users!attachments_uploaded_by_fkey(full_name)')
        .eq('record_type', recordType).in('record_id', recordIds)
        .order('created_at', { ascending: true });
      if (error) throw error;
      return data;
    },

    async upload(recordType, recordId, file) {
      const ext = (file.name.split('.').pop() || '').toLowerCase();
      if (!ALLOWED_EXTENSIONS.includes(ext)) {
        throw new Error(`File type not allowed. Accepted: ${ALLOWED_EXTENSIONS.join(', ')}`);
      }
      if (file.size > MAX_FILE_BYTES) {
        throw new Error('File is larger than the 20 MB limit.');
      }

      const existing = await this.list(recordType, recordId);
      const existingTotal = existing.reduce((sum, a) => sum + (a.file_size || 0), 0);
      if (existingTotal + file.size > MAX_TOTAL_BYTES) {
        throw new Error('Adding this file would exceed the 100 MB total limit for this item.');
      }

      const db = getSupabase();
      const session = await Auth.getSession();
      const safeName = file.name.replace(/[^\w.\-]/g, '_');
      const path = `${recordType}/${recordId}/${Date.now()}-${safeName}`;

      const { error: uploadError } = await db.storage.from('attachments')
        .upload(path, file, { contentType: file.type || 'application/octet-stream' });
      if (uploadError) throw uploadError;

      const { data, error } = await db.from('attachments').insert({
        record_type: recordType, record_id: recordId,
        filename: file.name, storage_path: path,
        mime_type: file.type || 'application/octet-stream', file_size: file.size,
        uploaded_by: session.user.id,
      }).select().single();
      if (error) {
        await db.storage.from('attachments').remove([path]);
        throw error;
      }
      await logAudit(recordId, `Uploaded ${file.name}`);
      return data;
    },

    async getSignedUrl(storagePath, expiresInSeconds = 300) {
      const db = getSupabase();
      const { data, error } = await db.storage.from('attachments').createSignedUrl(storagePath, expiresInSeconds);
      if (error) throw error;
      return data.signedUrl;
    },

    async remove(attachment) {
      const db = getSupabase();
      const { error: storageError } = await db.storage.from('attachments').remove([attachment.storage_path]);
      if (storageError) throw storageError;
      const { error } = await db.from('attachments').delete().eq('id', attachment.id);
      if (error) throw error;
    },
  };
})();
