"""Exact restricted schema frozen in M1B1_STORAGE_CONTRACT; no future-table placeholders."""

import sqlite3

APPLICATION_ID = 0x594B5031
SCHEMA_VERSION = 1
DDL = """CREATE TABLE repository (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1),
 identity BLOB NOT NULL CHECK(length(identity)=32),
 format INTEGER NOT NULL CHECK(format=1)
) STRICT;
CREATE TABLE workspace (
 id BLOB PRIMARY KEY NOT NULL CHECK(length(id)=16),
 cursor INTEGER CHECK(cursor>=0),
 next_seq INTEGER NOT NULL CHECK(next_seq BETWEEN 0 AND 9223372036854775807),
 version INTEGER NOT NULL CHECK(version=next_seq),
 CHECK((cursor IS NULL AND next_seq=0) OR (cursor IS NOT NULL AND cursor=next_seq-1)),
 FOREIGN KEY(id,cursor) REFERENCES capture(workspace,sequence) DEFERRABLE INITIALLY DEFERRED
) STRICT;
CREATE TABLE request (
 workspace BLOB NOT NULL REFERENCES workspace(id),
 key BLOB NOT NULL CHECK(length(key) BETWEEN 1 AND 128),
 arguments BLOB NOT NULL CHECK(length(arguments)=32),
 snapshot BLOB NOT NULL CHECK(length(snapshot)=32),
 expected_version INTEGER NOT NULL CHECK(expected_version>=0),
 parent INTEGER CHECK(parent>=0),
 state TEXT NOT NULL CHECK(state IN ('pending','completed')),
 result_sequence INTEGER CHECK(result_sequence>=0),
 result_version INTEGER CHECK(result_version>=0),
 changed INTEGER CHECK(changed IN (0,1)),
 PRIMARY KEY(workspace,key),
 UNIQUE(workspace,key,state),
 CHECK((state='pending' AND result_sequence IS NULL AND result_version IS NULL AND changed IS NULL)
 OR (state='completed' AND result_sequence IS NOT NULL AND result_version IS NOT NULL AND changed IS NOT NULL)),
 FOREIGN KEY(workspace,parent) REFERENCES capture(workspace,sequence),
 FOREIGN KEY(workspace,result_sequence) REFERENCES capture(workspace,sequence) DEFERRABLE INITIALLY DEFERRED,
 FOREIGN KEY(workspace,key,snapshot) REFERENCES root(workspace,key,snapshot) DEFERRABLE INITIALLY DEFERRED
) STRICT;
CREATE TABLE root (
 workspace BLOB NOT NULL,
 key BLOB NOT NULL,
 snapshot BLOB NOT NULL CHECK(length(snapshot)=32),
 PRIMARY KEY(workspace,key),
 UNIQUE(workspace,key,snapshot),
 FOREIGN KEY(workspace,key) REFERENCES request(workspace,key) DEFERRABLE INITIALLY DEFERRED
) STRICT;
CREATE TABLE capture (
 workspace BLOB NOT NULL REFERENCES workspace(id),
 sequence INTEGER NOT NULL CHECK(sequence BETWEEN 0 AND 9223372036854775806),
 parent INTEGER CHECK(parent>=0 AND parent<sequence),
 snapshot BLOB NOT NULL CHECK(length(snapshot)=32),
 request_key BLOB NOT NULL,
 request_state TEXT NOT NULL DEFAULT 'completed' CHECK(request_state='completed'),
 PRIMARY KEY(workspace,sequence),
 UNIQUE(workspace,request_key),
 FOREIGN KEY(workspace,parent) REFERENCES capture(workspace,sequence),
 FOREIGN KEY(workspace,request_key,request_state) REFERENCES request(workspace,key,state) DEFERRABLE INITIALLY DEFERRED
) STRICT;
CREATE TRIGGER repository_update BEFORE UPDATE ON repository BEGIN SELECT RAISE(ABORT,'immutable repository'); END;
CREATE TRIGGER repository_delete BEFORE DELETE ON repository BEGIN SELECT RAISE(ABORT,'retained repository'); END;
CREATE TRIGGER workspace_insert BEFORE INSERT ON workspace
 WHEN NEW.cursor IS NOT NULL OR NEW.next_seq!=0 OR NEW.version!=0
 BEGIN SELECT RAISE(ABORT,'initial workspace'); END;
CREATE TRIGGER workspace_update BEFORE UPDATE ON workspace
 WHEN NEW.id IS NOT OLD.id OR NEW.version!=OLD.version+1 OR NEW.next_seq!=OLD.next_seq+1
 OR NEW.cursor IS NOT OLD.next_seq
 OR NOT EXISTS(SELECT 1 FROM capture c JOIN request r ON r.workspace=c.workspace AND r.key=c.request_key
 WHERE c.workspace=OLD.id AND c.sequence=OLD.next_seq AND c.parent IS OLD.cursor
 AND r.state='pending' AND r.expected_version=OLD.version)
 BEGIN SELECT RAISE(ABORT,'capture cursor transition'); END;
CREATE TRIGGER workspace_delete BEFORE DELETE ON workspace BEGIN SELECT RAISE(ABORT,'retained workspace'); END;
CREATE TRIGGER request_insert BEFORE INSERT ON request
 WHEN NEW.state!='pending' OR NOT EXISTS(SELECT 1 FROM workspace w WHERE w.id=NEW.workspace
 AND w.version=NEW.expected_version AND w.cursor IS NEW.parent)
 BEGIN SELECT RAISE(ABORT,'pending request CAS'); END;
CREATE TRIGGER request_update BEFORE UPDATE ON request
 WHEN OLD.state!='pending' OR NEW.state!='completed'
 OR NEW.workspace IS NOT OLD.workspace OR NEW.key IS NOT OLD.key
 OR NEW.arguments IS NOT OLD.arguments OR NEW.snapshot IS NOT OLD.snapshot
 OR NEW.expected_version IS NOT OLD.expected_version OR NEW.parent IS NOT OLD.parent
 OR NOT EXISTS(SELECT 1 FROM workspace w JOIN capture c ON c.workspace=w.id AND c.sequence=NEW.result_sequence
 WHERE w.id=NEW.workspace AND c.snapshot=NEW.snapshot AND w.cursor=NEW.result_sequence
 AND w.version=NEW.result_version AND
 ((NEW.changed=1 AND c.request_key=NEW.key AND c.parent IS NEW.parent AND NEW.result_version=NEW.expected_version+1)
 OR (NEW.changed=0 AND c.sequence=NEW.parent AND NEW.result_version=NEW.expected_version)))
 BEGIN SELECT RAISE(ABORT,'completion transition'); END;
CREATE TRIGGER request_delete BEFORE DELETE ON request BEGIN SELECT RAISE(ABORT,'retained request'); END;
CREATE TRIGGER root_update BEFORE UPDATE ON root BEGIN SELECT RAISE(ABORT,'immutable root'); END;
CREATE TRIGGER root_delete BEFORE DELETE ON root BEGIN SELECT RAISE(ABORT,'retained root'); END;
CREATE TRIGGER capture_insert BEFORE INSERT ON capture
 WHEN NOT EXISTS(SELECT 1 FROM workspace w JOIN request r ON r.workspace=w.id
 WHERE w.id=NEW.workspace AND r.key=NEW.request_key AND r.state='pending'
 AND w.cursor IS NEW.parent AND w.next_seq=NEW.sequence AND w.version=r.expected_version
 AND r.parent IS NEW.parent AND r.snapshot=NEW.snapshot)
 BEGIN SELECT RAISE(ABORT,'capture allocation'); END;
CREATE TRIGGER capture_update BEFORE UPDATE ON capture BEGIN SELECT RAISE(ABORT,'immutable capture'); END;
CREATE TRIGGER capture_delete BEFORE DELETE ON capture BEGIN SELECT RAISE(ABORT,'retained capture'); END;
"""


def install(connection: sqlite3.Connection) -> None:
    statement = ""
    for line in DDL.splitlines(keepends=True):
        statement += line
        if sqlite3.complete_statement(statement):
            connection.execute(statement)
            statement = ""
    if statement.strip():
        raise RuntimeError("incomplete frozen schema")


def schema_rows(connection: sqlite3.Connection) -> list[tuple[str, str, str, str]]:
    return connection.execute(
        "SELECT type,name,tbl_name,sql FROM sqlite_schema WHERE sql IS NOT NULL ORDER BY type,name"
    ).fetchall()


def expected_schema() -> list[tuple[str, str, str, str]]:
    connection = sqlite3.connect(":memory:", autocommit=True)
    try:
        install(connection)
        return schema_rows(connection)
    finally:
        connection.close()
