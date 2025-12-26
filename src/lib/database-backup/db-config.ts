/**
 * 数据库连接配置
 * 从 DSN 环境变量解析数据库连接参数
 */

export interface DatabaseConfig {
  host: string;
  port: number;
  user: string;
  password: string;
  database: string;
}

/**
 * 从 PostgreSQL DSN 解析数据库连接配置
 *
 * 支持格式:
 * - postgresql://user:password@host:port/database
 * - postgres://user:password@host:port/database
 *
 * @param dsn - 数据库连接字符串
 * @returns DatabaseConfig
 */
export function parseDatabaseDSN(dsn: string): DatabaseConfig {
  try {
    const url = new URL(dsn);

    return {
      host: url.hostname || "localhost",
      port: url.port ? parseInt(url.port, 10) : 5432,
      user: url.username || "postgres",
      password: url.password || "",
      database: url.pathname.slice(1) || "postgres", // 移除开头的 /
    };
  } catch (error) {
    throw new Error(
      `Invalid database DSN: ${error instanceof Error ? error.message : String(error)}`
    );
  }
}

/**
 * 获取当前数据库配置
 */
export function getDatabaseConfig(): DatabaseConfig {
  const dsn = process.env.DSN;

  if (!dsn) {
    throw new Error("DSN environment variable is not set");
  }

  return parseDatabaseDSN(dsn);
}
