#include "SQLiteBridge.h"

int PortSQLConfigureSQLite(sqlite3 *database) {
    int enabled = 0;
    int result = sqlite3_db_config(database, SQLITE_DBCONFIG_DEFENSIVE, 1, &enabled);
    if (result != SQLITE_OK || enabled != 1) return result == SQLITE_OK ? SQLITE_ERROR : result;
    result = sqlite3_db_config(database, SQLITE_DBCONFIG_TRUSTED_SCHEMA, 0, &enabled);
    if (result != SQLITE_OK || enabled != 0) return result == SQLITE_OK ? SQLITE_ERROR : result;
    /* Apple's system library may omit extension loading entirely. */
    if (!sqlite3_compileoption_used("OMIT_LOAD_EXTENSION")) {
        result = sqlite3_db_config(database, SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION, 0, &enabled);
        if (result != SQLITE_OK || enabled != 0) return result == SQLITE_OK ? SQLITE_ERROR : result;
    }
    result = sqlite3_db_config(database, SQLITE_DBCONFIG_DQS_DDL, 0, &enabled);
    if (result != SQLITE_OK || enabled != 0) return result == SQLITE_OK ? SQLITE_ERROR : result;
    result = sqlite3_db_config(database, SQLITE_DBCONFIG_DQS_DML, 0, &enabled);
    return result == SQLITE_OK && enabled != 0 ? SQLITE_ERROR : result;
}
