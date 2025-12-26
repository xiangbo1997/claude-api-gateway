"use client";

import { Pause, Play, RefreshCw, Trash2 } from "lucide-react";
import { useRouter, useSearchParams } from "next/navigation";
import { useTranslations } from "next-intl";
import { useCallback, useEffect, useRef, useState, useTransition } from "react";
import { toast } from "sonner";
import { getUsageLogs } from "@/actions/usage-logs";
import {
  AlertDialog,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { formatTokenAmount } from "@/lib/utils";
import type { CurrencyCode } from "@/lib/utils/currency";
import { formatCurrency } from "@/lib/utils/currency";
import type { UsageLogsResult } from "@/repository/usage-logs";
import type { Key } from "@/types/key";
import type { ProviderDisplay } from "@/types/provider";
import type { BillingModelSource } from "@/types/system-config";
import type { UserDisplay } from "@/types/user";
import { UsageLogsFilters } from "./usage-logs-filters";
import { UsageLogsTable } from "./usage-logs-table";

interface UsageLogsViewProps {
  isAdmin: boolean;
  users: UserDisplay[];
  providers: ProviderDisplay[];
  initialKeys: Key[];
  searchParams: { [key: string]: string | string[] | undefined };
  currencyCode?: CurrencyCode;
  billingModelSource?: BillingModelSource;
}

export function UsageLogsView({
  isAdmin,
  users,
  providers,
  initialKeys,
  searchParams,
  currencyCode = "USD",
  billingModelSource = "original",
}: UsageLogsViewProps) {
  const t = useTranslations("dashboard");
  const tCommon = useTranslations("common");
  const router = useRouter();
  const params = useSearchParams();
  const [isPending, startTransition] = useTransition();
  const [data, setData] = useState<UsageLogsResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [isAutoRefresh, setIsAutoRefresh] = useState(true);
  const [isManualRefreshing, setIsManualRefreshing] = useState(false);

  // 清除日志相关状态
  const [isClearDialogOpen, setIsClearDialogOpen] = useState(false);
  const [clearPreviewCount, setClearPreviewCount] = useState<number | null>(null);
  const [isPreviewLoading, setIsPreviewLoading] = useState(false);
  const [isClearing, setIsClearing] = useState(false);

  // 追踪新增记录（用于动画高亮）
  const [newLogIds, setNewLogIds] = useState<Set<number>>(new Set());
  const previousLogsRef = useRef<Map<number, boolean>>(new Map());
  const previousParamsRef = useRef<string>("");

  // 从 URL 参数解析筛选条件
  // 使用毫秒时间戳传递时间，避免时区问题
  const filters: {
    userId?: number;
    keyId?: number;
    providerId?: number;
    startTime?: number;
    endTime?: number;
    statusCode?: number;
    excludeStatusCode200?: boolean;
    model?: string;
    endpoint?: string;
    minRetryCount?: number;
    page: number;
  } = {
    userId: searchParams.userId ? parseInt(searchParams.userId as string, 10) : undefined,
    keyId: searchParams.keyId ? parseInt(searchParams.keyId as string, 10) : undefined,
    providerId: searchParams.providerId
      ? parseInt(searchParams.providerId as string, 10)
      : undefined,
    // 使用毫秒时间戳，无时区歧义
    startTime: searchParams.startTime ? parseInt(searchParams.startTime as string, 10) : undefined,
    endTime: searchParams.endTime ? parseInt(searchParams.endTime as string, 10) : undefined,
    statusCode:
      searchParams.statusCode && searchParams.statusCode !== "!200"
        ? parseInt(searchParams.statusCode as string, 10)
        : undefined,
    excludeStatusCode200: searchParams.statusCode === "!200",
    model: searchParams.model as string | undefined,
    endpoint: searchParams.endpoint as string | undefined,
    minRetryCount: searchParams.minRetry
      ? parseInt(searchParams.minRetry as string, 10)
      : undefined,
    page: searchParams.page ? parseInt(searchParams.page as string, 10) : 1,
  };

  // 使用 ref 来存储最新的值,避免闭包陷阱
  const isPendingRef = useRef(isPending);
  const filtersRef = useRef(filters);

  isPendingRef.current = isPending;

  // 更新 filtersRef
  filtersRef.current = filters;

  // 加载数据
  // shouldDetectNew: 是否检测新增记录（只在刷新时为 true，筛选/翻页时为 false）
  const loadData = useCallback(
    async (shouldDetectNew = false) => {
      startTransition(async () => {
        const result = await getUsageLogs(filtersRef.current);
        if (result.ok && result.data) {
          // 只在刷新时检测新增（非筛选/翻页）
          if (shouldDetectNew && previousLogsRef.current.size > 0) {
            const newIds = result.data.logs
              .filter((log) => !previousLogsRef.current.has(log.id))
              .map((log) => log.id)
              .slice(0, 10); // 限制最多高亮 10 条

            if (newIds.length > 0) {
              setNewLogIds(new Set(newIds));
              // 800ms 后清除高亮
              setTimeout(() => setNewLogIds(new Set()), 800);
            }
          }

          // 更新记录缓存
          previousLogsRef.current = new Map(result.data.logs.map((log) => [log.id, true]));

          setData(result.data);
          setError(null);
        } else {
          setError(!result.ok && "error" in result ? result.error : t("logs.error.loadFailed"));
          setData(null);
        }
      });
    },
    [t]
  );

  // 手动刷新（检测新增）
  const handleManualRefresh = async () => {
    setIsManualRefreshing(true);
    await loadData(true); // 刷新时检测新增
    setTimeout(() => setIsManualRefreshing(false), 500);
  };

  // 构建清理条件（基于当前筛选条件）
  const buildCleanupConditions = useCallback(() => {
    const conditions: {
      beforeDate?: string;
      afterDate?: string;
      userIds?: number[];
      providerIds?: number[];
      statusCodes?: number[];
    } = {};

    // 时间范围
    if (filtersRef.current.endTime) {
      conditions.beforeDate = new Date(filtersRef.current.endTime).toISOString();
    }
    if (filtersRef.current.startTime) {
      conditions.afterDate = new Date(filtersRef.current.startTime).toISOString();
    }

    // 用户维度
    if (filtersRef.current.userId) {
      conditions.userIds = [filtersRef.current.userId];
    }

    // 供应商维度
    if (filtersRef.current.providerId) {
      conditions.providerIds = [filtersRef.current.providerId];
    }

    // 状态码维度
    if (filtersRef.current.statusCode) {
      conditions.statusCodes = [filtersRef.current.statusCode];
    }

    return conditions;
  }, []);

  // 检查是否有筛选条件
  const hasFilters = useCallback(() => {
    const f = filtersRef.current;
    return !!(
      f.userId ||
      f.keyId ||
      f.providerId ||
      f.startTime ||
      f.endTime ||
      f.statusCode ||
      f.excludeStatusCode200 ||
      f.model ||
      f.endpoint ||
      f.minRetryCount
    );
  }, []);

  // 打开清除对话框时预览将删除的数量
  const handleOpenClearDialog = async () => {
    setIsClearDialogOpen(true);
    setIsPreviewLoading(true);
    setClearPreviewCount(null);

    try {
      const conditions = buildCleanupConditions();
      const response = await fetch("/api/admin/log-cleanup/manual", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ ...conditions, dryRun: true }),
      });

      if (response.ok) {
        const result = await response.json();
        setClearPreviewCount(result.totalDeleted);
      } else {
        setClearPreviewCount(0);
      }
    } catch {
      setClearPreviewCount(0);
    } finally {
      setIsPreviewLoading(false);
    }
  };

  // 执行清除日志
  const handleClearLogs = async () => {
    setIsClearing(true);

    try {
      const conditions = buildCleanupConditions();
      const response = await fetch("/api/admin/log-cleanup/manual", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ ...conditions, dryRun: false }),
      });

      if (response.ok) {
        const result = await response.json();
        if (result.success) {
          toast.success(t("logs.actions.clearLogsSuccess", { count: result.totalDeleted }));
          // 清除后刷新数据
          previousLogsRef.current = new Map();
          await loadData(false);
        } else {
          toast.error(result.error || t("logs.actions.clearLogsError"));
        }
      } else {
        toast.error(t("logs.actions.clearLogsError"));
      }
    } catch {
      toast.error(t("logs.actions.clearLogsError"));
    } finally {
      setIsClearing(false);
      setIsClearDialogOpen(false);
    }
  };

  // 监听 URL 参数变化（筛选/翻页时重置缓存）
  useEffect(() => {
    const currentParams = params.toString();

    if (previousParamsRef.current && previousParamsRef.current !== currentParams) {
      // URL 变化 = 用户操作（筛选/翻页），重置缓存，不检测新增
      previousLogsRef.current = new Map();
      loadData(false);
    } else if (!previousParamsRef.current) {
      // 首次加载，不检测新增
      loadData(false);
    }

    previousParamsRef.current = currentParams;
  }, [params, loadData]);

  // 自动轮询（3秒间隔，检测新增）
  useEffect(() => {
    if (!isAutoRefresh) return;

    const intervalId = setInterval(() => {
      // 如果正在加载,跳过本次轮询
      if (isPendingRef.current) return;
      loadData(true); // 自动刷新时检测新增
    }, 3000); // 3 秒间隔

    return () => clearInterval(intervalId);
  }, [isAutoRefresh, loadData]);

  // 处理筛选条件变更
  const handleFilterChange = (newFilters: Omit<typeof filters, "page">) => {
    const query = new URLSearchParams();

    if (newFilters.userId) query.set("userId", newFilters.userId.toString());
    if (newFilters.keyId) query.set("keyId", newFilters.keyId.toString());
    if (newFilters.providerId) query.set("providerId", newFilters.providerId.toString());
    // 使用毫秒时间戳传递时间，无时区歧义
    if (newFilters.startTime) query.set("startTime", newFilters.startTime.toString());
    if (newFilters.endTime) query.set("endTime", newFilters.endTime.toString());
    if (newFilters.excludeStatusCode200) {
      query.set("statusCode", "!200");
    } else if (newFilters.statusCode !== undefined) {
      query.set("statusCode", newFilters.statusCode.toString());
    }
    if (newFilters.model) query.set("model", newFilters.model);
    if (newFilters.endpoint) query.set("endpoint", newFilters.endpoint);
    if (newFilters.minRetryCount !== undefined) {
      query.set("minRetry", newFilters.minRetryCount.toString());
    }

    router.push(`/dashboard/logs?${query.toString()}`);
  };

  // 处理分页
  const handlePageChange = (page: number) => {
    const query = new URLSearchParams(params.toString());
    query.set("page", page.toString());
    router.push(`/dashboard/logs?${query.toString()}`);
  };

  return (
    <div className="space-y-6">
      {/* 统计卡片 */}
      {data && (
        <div className="grid gap-4 md:grid-cols-4">
          <Card>
            <CardHeader className="pb-3">
              <CardDescription>{t("logs.stats.totalRequests")}</CardDescription>
              <CardTitle className="text-3xl font-mono">
                {data.summary.totalRequests.toLocaleString()}
              </CardTitle>
            </CardHeader>
          </Card>

          <Card>
            <CardHeader className="pb-3">
              <CardDescription>{t("logs.stats.totalAmount")}</CardDescription>
              <CardTitle className="text-3xl font-mono">
                {formatCurrency(data.summary.totalCost, currencyCode)}
              </CardTitle>
            </CardHeader>
          </Card>

          <Card>
            <CardHeader className="pb-3">
              <CardDescription>{t("logs.stats.totalTokens")}</CardDescription>
              <CardTitle className="text-3xl font-mono">
                {formatTokenAmount(data.summary.totalTokens)}
              </CardTitle>
            </CardHeader>
            <CardContent className="text-xs text-muted-foreground space-y-1">
              <div className="flex justify-between">
                <span>{t("logs.stats.input")}:</span>
                <span className="font-mono">
                  {formatTokenAmount(data.summary.totalInputTokens)}
                </span>
              </div>
              <div className="flex justify-between">
                <span>{t("logs.stats.output")}:</span>
                <span className="font-mono">
                  {formatTokenAmount(data.summary.totalOutputTokens)}
                </span>
              </div>
            </CardContent>
          </Card>

          <Card>
            <CardHeader className="pb-3">
              <CardDescription>{t("logs.stats.cacheTokens")}</CardDescription>
              <CardTitle className="text-3xl font-mono">
                {formatTokenAmount(
                  data.summary.totalCacheCreationTokens + data.summary.totalCacheReadTokens
                )}
              </CardTitle>
            </CardHeader>
            <CardContent className="text-xs text-muted-foreground space-y-1">
              <div className="flex justify-between">
                <span>{t("logs.stats.write")}:</span>
                <span className="font-mono">
                  {formatTokenAmount(data.summary.totalCacheCreationTokens)}
                </span>
              </div>
              <div className="flex justify-between">
                <span>{t("logs.stats.read")}:</span>
                <span className="font-mono">
                  {formatTokenAmount(data.summary.totalCacheReadTokens)}
                </span>
              </div>
            </CardContent>
          </Card>
        </div>
      )}

      {/* 筛选器 */}
      <Card>
        <CardHeader>
          <CardTitle>{t("title.filterCriteria")}</CardTitle>
        </CardHeader>
        <CardContent>
          <UsageLogsFilters
            isAdmin={isAdmin}
            users={users}
            providers={providers}
            initialKeys={initialKeys}
            filters={filters}
            onChange={handleFilterChange}
            onReset={() => router.push("/dashboard/logs")}
          />
        </CardContent>
      </Card>

      {/* 数据表格 */}
      <Card>
        <CardHeader>
          <div className="flex items-center justify-between">
            <CardTitle>{t("title.usageLogs")}</CardTitle>
            <div className="flex items-center gap-2">
              {/* 手动刷新按钮 */}
              <Button
                variant="outline"
                size="sm"
                onClick={handleManualRefresh}
                disabled={isPending}
                className="gap-2"
              >
                <RefreshCw className={`h-4 w-4 ${isManualRefreshing ? "animate-spin" : ""}`} />
                {t("logs.actions.refresh")}
              </Button>

              {/* 自动刷新开关 */}
              <Button
                variant={isAutoRefresh ? "default" : "outline"}
                size="sm"
                onClick={() => setIsAutoRefresh(!isAutoRefresh)}
                className="gap-2"
              >
                {isAutoRefresh ? (
                  <>
                    <Pause className="h-4 w-4" />
                    {t("logs.actions.stopAutoRefresh")}
                  </>
                ) : (
                  <>
                    <Play className="h-4 w-4" />
                    {t("logs.actions.startAutoRefresh")}
                  </>
                )}
              </Button>

              {/* 清除日志按钮（仅管理员可见） */}
              {isAdmin && (
                <AlertDialog open={isClearDialogOpen} onOpenChange={setIsClearDialogOpen}>
                  <AlertDialogTrigger asChild>
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={handleOpenClearDialog}
                      className="gap-2 text-destructive hover:text-destructive"
                    >
                      <Trash2 className="h-4 w-4" />
                      {hasFilters() ? t("logs.actions.clearLogsFiltered") : t("logs.actions.clearLogsAll")}
                    </Button>
                  </AlertDialogTrigger>
                  <AlertDialogContent>
                    <AlertDialogHeader>
                      <AlertDialogTitle>{t("logs.actions.clearLogsConfirmTitle")}</AlertDialogTitle>
                      <AlertDialogDescription className="space-y-2">
                        <span className="block">{t("logs.actions.clearLogsConfirmDescription")}</span>
                        <span className="block font-semibold text-destructive">
                          {t("logs.actions.clearLogsWarning")}
                        </span>
                        <span className="block font-mono text-sm">
                          {isPreviewLoading
                            ? t("logs.actions.clearLogsPreviewLoading")
                            : clearPreviewCount !== null
                              ? t("logs.actions.clearLogsPreview", { count: clearPreviewCount.toLocaleString() })
                              : ""}
                        </span>
                      </AlertDialogDescription>
                    </AlertDialogHeader>
                    <AlertDialogFooter>
                      <AlertDialogCancel disabled={isClearing}>
                        {tCommon("cancel")}
                      </AlertDialogCancel>
                      <Button
                        onClick={handleClearLogs}
                        disabled={isClearing || isPreviewLoading || clearPreviewCount === 0}
                        variant="destructive"
                      >
                        {isClearing ? t("logs.actions.clearing") : t("logs.actions.clearLogs")}
                      </Button>
                    </AlertDialogFooter>
                  </AlertDialogContent>
                </AlertDialog>
              )}
            </div>
          </div>
        </CardHeader>
        <CardContent>
          {error ? (
            <div className="text-center py-8 text-destructive">{error}</div>
          ) : !data ? (
            <div className="text-center py-8 text-muted-foreground">{t("logs.stats.loading")}</div>
          ) : (
            <UsageLogsTable
              logs={data.logs}
              total={data.total}
              page={filters.page || 1}
              pageSize={50}
              onPageChange={handlePageChange}
              isPending={isPending}
              newLogIds={newLogIds}
              currencyCode={currencyCode}
              billingModelSource={billingModelSource}
            />
          )}
        </CardContent>
      </Card>
    </div>
  );
}
