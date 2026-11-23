package com.resumeallinone.resume_all_in_one_client;

import android.content.ContentValues;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.os.Build;
import android.os.Bundle;
import android.test.InstrumentationTestCase;
import android.test.InstrumentationTestRunner;
import android.util.Base64;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.File;
import java.io.FileInputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Iterator;
import java.util.List;

/**
 * Synthetic emulator upgrade driver. Never launches an Activity or performs migration.
 * Methods intentionally do not use JUnit's test prefix: invoke class#method explicitly.
 * Default instrumentation discovery does not count these opt-in operations as passed tests.
 */
@SuppressWarnings("deprecation")
public final class UpgradeDataTest extends InstrumentationTestCase {
    private static final String OWNER = "G5-synthetic-20261012";
    private static final String PACKAGE = "com.resumeallinone.resume_all_in_one_client";
    private static final String[] ROW_TABLES = {"resume_documents", "resume_versions", "app_settings"};

    private Bundle arguments() {
        return ((InstrumentationTestRunner) getInstrumentation()).getArguments();
    }

    private void requireSyntheticEmulator() {
        assertEquals("Explicit synthetic fixture ownership required", OWNER, arguments().getString("owner"));
        assertEquals(PACKAGE, getInstrumentation().getTargetContext().getPackageName());
        assertTrue("Only a dedicated Android emulator is supported",
                "ranchu".equals(Build.HARDWARE) || "goldfish".equals(Build.HARDWARE));
    }

    private JSONObject fixture() throws Exception {
        requireSyntheticEmulator();
        String encoded = arguments().getString("fixture");
        assertNotNull("Pass a Base64 synthetic fixture", encoded);
        assertTrue("Fixture exceeds bounded instrumentation input", encoded.length() <= 90000);
        JSONObject result = new JSONObject(new String(Base64.decode(encoded, Base64.DEFAULT), StandardCharsets.UTF_8));
        assertEquals(OWNER, result.getString("owner"));
        int version = result.getInt("databaseSchema");
        assertTrue("Only frozen historical v1/v2 fixture schemas", version == 1 || version == 2);
        return result;
    }

    private File databaseFile() throws Exception {
        File base = new File(getInstrumentation().getTargetContext().getApplicationInfo().dataDir, "app_flutter");
        File database = new File(base, "resume_all_in_one.sqlite");
        assertEquals(base.getCanonicalFile(), database.getCanonicalFile().getParentFile());
        return database;
    }

    public void seedHistoricalDatabase() throws Exception {
        JSONObject input = fixture();
        File file = databaseFile();
        assertFalse("Never overwrite an existing application database", file.exists());
        assertFalse(new File(file.getPath() + "-wal").exists());
        assertFalse(new File(file.getPath() + "-shm").exists());
        assertTrue(file.getParentFile().isDirectory() || file.getParentFile().mkdirs());
        SQLiteDatabase database = SQLiteDatabase.openDatabase(file.getPath(), null,
                SQLiteDatabase.CREATE_IF_NECESSARY | SQLiteDatabase.NO_LOCALIZED_COLLATORS);
        try {
            database.beginTransaction();
            try {
                JSONArray statements = input.getJSONArray("historicalDdl");
                assertTrue(statements.length() >= 2 && statements.length() <= 12);
                for (int index = 0; index < statements.length(); index++) {
                    String sql = statements.getString(index);
                    // Only reviewed frozen DDL, no ATTACH, triggers, destructive or runtime SQL.
                    assertTrue(sql.startsWith("CREATE TABLE ") || sql.startsWith("CREATE INDEX "));
                    assertFalse(sql.contains(";"));
                    database.execSQL(sql);
                }
                JSONObject rows = input.getJSONObject("rows");
                for (String table : ROW_TABLES) {
                    JSONArray entries = rows.getJSONArray(table);
                    assertTrue(entries.length() <= 8);
                    for (int index = 0; index < entries.length(); index++) {
                        JSONObject row = entries.getJSONObject(index);
                        ContentValues values = new ContentValues();
                        Iterator<String> keys = row.keys();
                        while (keys.hasNext()) {
                            String key = keys.next();
                            assertTrue(key.matches("[a-z_]+"));
                            Object value = row.get(key);
                            if (value == JSONObject.NULL) values.putNull(key);
                            else if (value instanceof Number) values.put(key, ((Number) value).longValue());
                            else values.put(key, (String) value);
                        }
                        assertTrue(database.insertOrThrow(table, null, values) >= 0);
                    }
                }
                database.setVersion(input.getInt("databaseSchema"));
                database.setTransactionSuccessful();
            } finally {
                database.endTransaction();
            }
            JSONObject result = snapshot(database);
            verifyRows(input, result);
            assertEquals(input.getInt("databaseSchema"), result.getInt("userVersion"));
            emit("seed", result);
        } finally {
            database.close();
        }
    }

    public void verifyHistoricalDatabase() throws Exception {
        JSONObject input = fixture();
        SQLiteDatabase database = readOnlyDatabase();
        try {
            JSONObject result = snapshot(database);
            verifyRows(input, result);
            assertEquals(input.getInt("databaseSchema"), result.getInt("userVersion"));
            emit("before", result);
        } finally { database.close(); }
    }

    public void verifyUpgradedDatabase() throws Exception {
        JSONObject input = fixture();
        SQLiteDatabase database = readOnlyDatabase();
        try {
            JSONObject result = snapshot(database);
            verifyRows(input, result);
            assertEquals("Release must perform the migration itself", 4, result.getInt("userVersion"));
            assertEquals(canonical(input.getJSONObject("expectedCurrentStructure")),
                    canonical(result.getJSONObject("structure")));
            emit("after", result);
        } finally { database.close(); }
    }

    public void captureDatabaseSnapshot() throws Exception {
        requireSyntheticEmulator();
        SQLiteDatabase database = readOnlyDatabase();
        try { emit("snapshot", snapshot(database)); }
        finally { database.close(); }
    }

    private SQLiteDatabase readOnlyDatabase() throws Exception {
        File file = databaseFile();
        assertTrue("Database must already exist", file.isFile());
        // Opening through Android SQLite does not run Drift migrations or write app rows.
        return SQLiteDatabase.openDatabase(file.getPath(), null,
                SQLiteDatabase.OPEN_READONLY | SQLiteDatabase.NO_LOCALIZED_COLLATORS);
    }

    private static JSONArray query(SQLiteDatabase database, String sql) throws Exception {
        JSONArray result = new JSONArray();
        try (Cursor cursor = database.rawQuery(sql, null)) {
            while (cursor.moveToNext()) {
                JSONObject row = new JSONObject();
                for (int column = 0; column < cursor.getColumnCount(); column++) {
                    Object value;
                    switch (cursor.getType(column)) {
                        case Cursor.FIELD_TYPE_NULL: value = JSONObject.NULL; break;
                        case Cursor.FIELD_TYPE_INTEGER: value = cursor.getLong(column); break;
                        case Cursor.FIELD_TYPE_FLOAT: value = cursor.getDouble(column); break;
                        case Cursor.FIELD_TYPE_BLOB: value = Base64.encodeToString(cursor.getBlob(column), Base64.NO_WRAP); break;
                        default: value = cursor.getString(column);
                    }
                    row.put(cursor.getColumnName(column), value);
                }
                result.put(row);
            }
        }
        return result;
    }

    private static String canonicalDdl(String sql) {
        return sql.replace("IF NOT EXISTS ", "").replace("\"", "").replaceAll("\\s+", " ").trim();
    }

    private static JSONObject snapshot(SQLiteDatabase database) throws Exception {
        JSONObject result = new JSONObject();
        result.put("owner", OWNER);
        result.put("userVersion", database.getVersion());
        JSONObject rows = new JSONObject();
        JSONArray entities = query(database, "SELECT type, name, tbl_name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name");
        List<String> tables = new ArrayList<>();
        List<String> indexes = new ArrayList<>();
        for (int index = 0; index < entities.length(); index++) {
            JSONObject entity = entities.getJSONObject(index);
            String name = entity.getString("name");
            if (!name.matches("[a-z_]+")) throw new AssertionError("Unexpected database entity");
            if (entity.getString("type").equals("table")) tables.add(name);
            if (entity.getString("type").equals("index")) indexes.add(name);
            entity.put("sql", canonicalDdl(entity.getString("sql")));
        }
        for (String table : ROW_TABLES) {
            String order = table.equals("app_settings") ? "setting_key" : "id";
            rows.put(table, tables.contains(table) ? query(database, "SELECT * FROM \"" + table + "\" ORDER BY " + order) : new JSONArray());
        }
        JSONObject structure = new JSONObject();
        structure.put("entities", entities);
        JSONObject columns = new JSONObject(), foreignKeys = new JSONObject(), indexLists = new JSONObject(), indexColumns = new JSONObject();
        for (String name : tables) {
            columns.put(name, query(database, "PRAGMA table_info(\"" + name + "\")"));
            foreignKeys.put(name, query(database, "PRAGMA foreign_key_list(\"" + name + "\")"));
            indexLists.put(name, query(database, "PRAGMA index_list(\"" + name + "\")"));
        }
        for (String name : indexes) indexColumns.put(name, query(database, "PRAGMA index_xinfo(\"" + name + "\")"));
        structure.put("columns", columns); structure.put("foreignKeys", foreignKeys);
        structure.put("indexes", indexLists); structure.put("indexColumns", indexColumns);
        result.put("rows", rows); result.put("structure", structure);
        return result;
    }

    private static void verifyRows(JSONObject input, JSONObject result) throws Exception {
        assertEquals("Every stored field, raw JSON, parent and microsecond must survive", canonical(input.getJSONObject("rows")), canonical(result.getJSONObject("rows")));
    }

    private static String canonical(Object value) throws Exception {
        if (value instanceof JSONObject) {
            JSONObject object = (JSONObject) value;
            List<String> keys = new ArrayList<>();
            Iterator<String> iterator = object.keys();
            while (iterator.hasNext()) keys.add(iterator.next());
            Collections.sort(keys);
            StringBuilder text = new StringBuilder("{");
            for (String key : keys) {
                if (text.length() > 1) text.append(',');
                text.append(JSONObject.quote(key)).append(':').append(canonical(object.get(key)));
            }
            return text.append('}').toString();
        }
        if (value instanceof JSONArray) {
            JSONArray array = (JSONArray) value;
            StringBuilder text = new StringBuilder("[");
            for (int index = 0; index < array.length(); index++) {
                if (index > 0) text.append(',');
                text.append(canonical(array.get(index)));
            }
            return text.append(']').toString();
        }
        return value instanceof String ? JSONObject.quote((String) value) : String.valueOf(value);
    }

    private void emit(String kind, JSONObject result) {
        String encoded = Base64.encodeToString(result.toString().getBytes(StandardCharsets.UTF_8), Base64.NO_WRAP);
        int parts = (encoded.length() + 2999) / 3000;
        for (int part = 0; part < parts; part++) {
            Bundle status = new Bundle();
            status.putString("g5_kind", kind);
            status.putInt("g5_part", part);
            status.putInt("g5_parts", parts);
            status.putString("g5_base64", encoded.substring(part * 3000, Math.min(encoded.length(), (part + 1) * 3000)));
            getInstrumentation().sendStatus(0, status);
        }
    }

    /** Read only bounded private export files from the synthetic test target. */
    public void listSyntheticExports() throws Exception {
        requireSyntheticEmulator();
        File folder = new File(getInstrumentation().getTargetContext().getApplicationInfo().dataDir, "app_flutter/resume_exports");
        JSONArray entries = new JSONArray();
        File[] files = folder.listFiles();
        if (files != null) for (File file : files) {
            if (file.isFile() && file.getName().matches("[^/\\\\]+\\.(json|md|docx|pdf)")
                    && folder.getCanonicalFile().equals(file.getCanonicalFile().getParentFile())) {
                JSONObject entry = new JSONObject();
                entry.put("name", file.getName()); entry.put("length", file.length());
                entries.put(entry);
            }
        }
        JSONObject result = new JSONObject(); result.put("exports", entries);
        emit("exports", result);
    }

    /** Read only bounded private export files from the synthetic test target. */
    public void readSyntheticExport() throws Exception {
        requireSyntheticEmulator();
        File folder = new File(getInstrumentation().getTargetContext().getApplicationInfo().dataDir, "app_flutter/resume_exports");
        String name = arguments().getString("exportName");
        assertNotNull(name);
        assertTrue(name.matches("[^/\\\\]+\\.(json|md|docx|pdf)"));
        File file = new File(folder, name);
        assertEquals(folder.getCanonicalFile(), file.getCanonicalFile().getParentFile());
        assertTrue(file.isFile() && file.length() <= 8 * 1024 * 1024);
        byte[] bytes = new byte[(int) file.length()];
        try (FileInputStream stream = new FileInputStream(file)) {
            int offset = 0, count;
            while (offset < bytes.length && (count = stream.read(bytes, offset, bytes.length - offset)) > 0) offset += count;
            assertEquals(bytes.length, offset);
            assertEquals(-1, stream.read());
        }
        JSONObject result = new JSONObject();
        result.put("name", name); result.put("bytes", Base64.encodeToString(bytes, Base64.NO_WRAP));
        emit("export", result);
    }
}
