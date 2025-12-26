import { getEnvConfig } from "./env.schema";

/**
 * 简化的配置访问
 * 使用 getter 延迟求值，避免构建时触发环境变量验证
 */
export const config = {
  auth: {
    get adminToken() {
      return getEnvConfig().ADMIN_TOKEN;
    },
  },
};
