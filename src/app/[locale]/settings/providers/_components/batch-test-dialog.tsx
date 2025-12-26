"use client";

import { FlaskConical, Loader2, X, ExternalLink } from "lucide-react";
import { useTranslations } from "next-intl";
import { useCallback, useRef, useState } from "react";
import { toast } from "sonner";
import {
  editProvider,
  getUnmaskedProviderKey,
  testProviderGemini,
  testProviderUnified,
} from "@/actions/providers";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import type { ProviderDisplay, ProviderType } from "@/types/provider";
import { TestResultCard, type UnifiedTestResultData } from "./forms/test-result-card";

interface BatchTestDialogProps {
  providers: ProviderDisplay[];
}

type TestResult = {
  providerId: number;
  providerName: string;
  status: "pending" | "testing" | "success" | "failed";
  latencyMs?: number;
  errorMessage?: string;
  // 详细测试结果数据，用于展示详情
  resultData?: UnifiedTestResultData;
};

const COMMON_MODELS = [
  "claude-sonnet-4-20250514",
  "claude-3-5-sonnet-20241022",
  "claude-3-5-haiku-20241022",
];

// 判断是否为 Gemini 类型供应商
const isGeminiProvider = (providerType: ProviderType | null | undefined): boolean => {
  return providerType === "gemini" || providerType === "gemini-cli";
};

// 根据供应商类型推断 subStatus
const inferSubStatus = (
  isSuccess: boolean,
  message: string
):
  | "success"
  | "auth_error"
  | "server_error"
  | "network_error"
  | "client_error"
  | "rate_limit"
  | "slow_latency"
  | "content_mismatch"
  | "invalid_request" => {
  if (isSuccess) return "success";
  const msg = message.toLowerCase();
  if (msg.includes("429") || msg.includes("rate") || msg.includes("限流") || msg.includes("quota")) {
    return "rate_limit";
  }
  if (msg.includes("401") || msg.includes("403") || msg.includes("认证") || msg.includes("auth")) {
    return "auth_error";
  }
  if (
    msg.includes("timeout") ||
    msg.includes("超时") ||
    msg.includes("econnrefused") ||
    msg.includes("dns")
  ) {
    return "network_error";
  }
  if (msg.includes("500") || msg.includes("502") || msg.includes("503") || msg.includes("504")) {
    return "server_error";
  }
  return "client_error";
};

export function BatchTestDialog({ providers }: BatchTestDialogProps) {
  const t = useTranslations("settings.providers.batchTest");
  const [open, setOpen] = useState(false);
  const [model, setModel] = useState(COMMON_MODELS[0]);
  const [testing, setTesting] = useState(false);
  const [results, setResults] = useState<TestResult[]>([]);
  const [selectedFailed, setSelectedFailed] = useState<Set<number>>(new Set());
  const [currentIndex, setCurrentIndex] = useState(0);
  const [viewingResult, setViewingResult] = useState<TestResult | null>(null);
  const stopRef = useRef(false);

  const enabledProviders = providers.filter((p) => p.isEnabled);

  const handleStartTest = useCallback(async () => {
    if (!model.trim()) return;

    stopRef.current = false;
    setTesting(true);
    setSelectedFailed(new Set());

    // 初始化结果
    const initialResults: TestResult[] = enabledProviders.map((p) => ({
      providerId: p.id,
      providerName: p.name,
      status: "pending",
    }));
    setResults(initialResults);

    // 串行测试每个供应商
    for (let i = 0; i < enabledProviders.length; i++) {
      if (stopRef.current) break;

      setCurrentIndex(i);
      const provider = enabledProviders[i];

      // 更新为测试中状态
      setResults((prev) =>
        prev.map((r) =>
          r.providerId === provider.id ? { ...r, status: "testing" } : r
        )
      );

      try {
        // 先获取 API Key
        const keyResult = await getUnmaskedProviderKey(provider.id);
        if (!keyResult.ok || !keyResult.data) {
          const errorMsg = "Failed to get API key";
          setResults((prev) =>
            prev.map((r) =>
              r.providerId === provider.id
                ? {
                    ...r,
                    status: "failed",
                    errorMessage: errorMsg,
                    resultData: {
                      success: false,
                      status: "red",
                      subStatus: "auth_error",
                      message: errorMsg,
                      latencyMs: 0,
                      errorMessage: errorMsg,
                      testedAt: new Date().toISOString(),
                      validationDetails: {
                        httpPassed: false,
                        latencyPassed: false,
                        contentPassed: false,
                      },
                    },
                  }
                : r
            )
          );
          continue;
        }

        // 根据供应商类型选择测试方法
        let result;
        if (isGeminiProvider(provider.providerType)) {
          // Gemini 类型使用专用测试方法
          result = await testProviderGemini({
            providerUrl: provider.url,
            apiKey: keyResult.data.key,
            model: model.trim(),
            proxyUrl: provider.proxyUrl,
            proxyFallbackToDirect: provider.proxyFallbackToDirect,
          });
        } else {
          // 其他类型使用统一测试方法，使用 cc_base 预设（与单个供应商测试一致）
          result = await testProviderUnified({
            providerUrl: provider.url,
            apiKey: keyResult.data.key,
            providerType: provider.providerType,
            model: model.trim(),
            proxyUrl: provider.proxyUrl,
            proxyFallbackToDirect: provider.proxyFallbackToDirect,
            preset: "cc_base",
            successContains: "isNewTopic",
          });
        }

        // Gemini 类型供应商返回数据在 details 下，其他类型直接在 data 下
        const isGemini = isGeminiProvider(provider.providerType);
        const isSuccess = result.ok && result.data?.success;

        // 根据供应商类型提取数据
        let errorMsg: string | undefined;
        let latencyMs: number;
        let resultModel: string | undefined;
        let content: string | undefined;
        let rawResponse: string | undefined;
        let httpStatusCode: number | undefined;
        let usage: { input_tokens?: number; output_tokens?: number; cache_creation_input_tokens?: number; cache_read_input_tokens?: number } | undefined;
        let streamInfo: { chunksReceived?: number; format?: string } | undefined;
        let validationDetails: { httpPassed: boolean; latencyPassed: boolean; contentPassed: boolean } | undefined;

        if (result.ok) {
          if (isGemini) {
            // Gemini 类型：数据在 result.data.details 下
            const geminiData = result.data as { success: boolean; message: string; details?: { responseTime?: number; model?: string; content?: string; rawResponse?: string; httpStatusCode?: number; usage?: Record<string, unknown>; streamInfo?: { chunksReceived?: number }; validationDetails?: { httpPassed: boolean; latencyPassed: boolean; contentPassed: boolean }; error?: string } };
            const details = geminiData?.details;
            errorMsg = details?.error || geminiData?.message;
            latencyMs = details?.responseTime ?? 0;
            resultModel = details?.model;
            content = details?.content;
            rawResponse = details?.rawResponse;
            httpStatusCode = details?.httpStatusCode;
            usage = details?.usage as typeof usage;
            streamInfo = details?.streamInfo;
            validationDetails = details?.validationDetails;
          } else {
            // 非 Gemini 类型：数据直接在 result.data 下
            const data = result.data as UnifiedTestResultData | undefined;
            errorMsg = data?.errorMessage;
            latencyMs = data?.latencyMs ?? 0;
            resultModel = data?.model;
            content = data?.content;
            rawResponse = data?.rawResponse;
            httpStatusCode = data?.httpStatusCode;
            usage = data?.usage ? {
              input_tokens: data.usage.inputTokens,
              output_tokens: data.usage.outputTokens,
              cache_creation_input_tokens: data.usage.cacheCreationInputTokens,
              cache_read_input_tokens: data.usage.cacheReadInputTokens,
            } : undefined;
            streamInfo = data?.streamInfo
              ? { chunksReceived: data.streamInfo.chunksReceived, format: undefined }
              : undefined;
            validationDetails = data?.validationDetails;
          }
        } else {
          errorMsg = result.error;
          latencyMs = 0;
        }

        const message = isSuccess
          ? `Test passed in ${latencyMs}ms`
          : errorMsg || "Test failed";

        // 构建详细结果数据
        const resultData: UnifiedTestResultData = {
          success: isSuccess,
          status: isSuccess ? "green" : "red",
          subStatus: inferSubStatus(isSuccess, errorMsg || ""),
          message,
          latencyMs,
          errorMessage: errorMsg,
          testedAt: new Date().toISOString(),
          model: resultModel,
          content,
          rawResponse,
          httpStatusCode,
          usage: usage
            ? {
                inputTokens: usage.input_tokens ?? 0,
                outputTokens: usage.output_tokens ?? 0,
                cacheCreationInputTokens: usage.cache_creation_input_tokens,
                cacheReadInputTokens: usage.cache_read_input_tokens,
              }
            : undefined,
          streamInfo: streamInfo
            ? {
                isStreaming: true,
                chunksReceived: streamInfo.chunksReceived,
              }
            : undefined,
          validationDetails: validationDetails ?? {
            httpPassed: false,
            latencyPassed: false,
            contentPassed: false,
          },
        };

        setResults((prev) =>
          prev.map((r) =>
            r.providerId === provider.id
              ? {
                  ...r,
                  status: isSuccess ? "success" : "failed",
                  latencyMs,
                  errorMessage: errorMsg,
                  resultData,
                }
              : r
          )
        );
      } catch (error) {
        const errorMsg = error instanceof Error ? error.message : "Unknown error";
        setResults((prev) =>
          prev.map((r) =>
            r.providerId === provider.id
              ? {
                  ...r,
                  status: "failed",
                  errorMessage: errorMsg,
                  resultData: {
                    success: false,
                    status: "red",
                    subStatus: inferSubStatus(false, errorMsg),
                    message: errorMsg,
                    latencyMs: 0,
                    errorMessage: errorMsg,
                    testedAt: new Date().toISOString(),
                    validationDetails: {
                      httpPassed: false,
                      latencyPassed: false,
                      contentPassed: false,
                    },
                  },
                }
              : r
          )
        );
      }
    }

    setTesting(false);
  }, [enabledProviders, model]);

  const handleStop = () => {
    stopRef.current = true;
  };

  const handleDisableSelected = async () => {
    const toDisable = Array.from(selectedFailed);
    let successCount = 0;

    for (const providerId of toDisable) {
      const result = await editProvider(providerId, { is_enabled: false });
      if (result.ok) successCount++;
    }

    if (successCount > 0) {
      toast.success(t("disableSuccess", { count: successCount }));
      setSelectedFailed(new Set());
    } else {
      toast.error(t("disableFailed"));
    }
  };

  const handleDisableAllFailed = async () => {
    const failedIds = results.filter((r) => r.status === "failed").map((r) => r.providerId);
    let successCount = 0;

    for (const providerId of failedIds) {
      const result = await editProvider(providerId, { is_enabled: false });
      if (result.ok) successCount++;
    }

    if (successCount > 0) {
      toast.success(t("disableSuccess", { count: successCount }));
    } else {
      toast.error(t("disableFailed"));
    }
  };

  const toggleSelectFailed = (providerId: number) => {
    setSelectedFailed((prev) => {
      const next = new Set(prev);
      if (next.has(providerId)) {
        next.delete(providerId);
      } else {
        next.add(providerId);
      }
      return next;
    });
  };

  const selectAllFailed = () => {
    const failedIds = results.filter((r) => r.status === "failed").map((r) => r.providerId);
    setSelectedFailed(new Set(failedIds));
  };

  const successCount = results.filter((r) => r.status === "success").length;
  const failedCount = results.filter((r) => r.status === "failed").length;
  const hasResults = results.length > 0 && !testing;

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="outline" size="sm">
          <FlaskConical className="h-4 w-4 mr-1" />
          {t("triggerButton")}
        </Button>
      </DialogTrigger>
      <DialogContent className="max-w-2xl">
        <DialogHeader>
          <DialogTitle>{t("title")}</DialogTitle>
          <DialogDescription>{t("description")}</DialogDescription>
        </DialogHeader>

        <div className="space-y-4">
          {/* 模型选择 */}
          <div className="space-y-2">
            <Label>{t("selectModel")}</Label>
            <Input
              value={model}
              onChange={(e) => setModel(e.target.value)}
              placeholder={t("selectModelPlaceholder")}
              disabled={testing}
            />
            <div className="flex flex-wrap gap-1">
              <span className="text-xs text-muted-foreground">{t("commonModels")}:</span>
              {COMMON_MODELS.map((m) => (
                <Badge
                  key={m}
                  variant={model === m ? "default" : "outline"}
                  className="cursor-pointer text-xs"
                  onClick={() => !testing && setModel(m)}
                >
                  {m}
                </Badge>
              ))}
            </div>
          </div>

          {/* 测试进度 */}
          {testing && (
            <div className="text-sm text-muted-foreground">
              {t("testingProgress", { current: currentIndex + 1, total: enabledProviders.length })}
            </div>
          )}

          {/* 结果列表 */}
          {results.length > 0 && (
            <div className="h-[300px] border rounded-md overflow-auto">
              <div className="p-2 space-y-1">
                {results.map((r) => (
                  <div
                    key={r.providerId}
                    className="flex items-center justify-between p-2 rounded hover:bg-muted/50"
                  >
                    <div className="flex items-center gap-2">
                      {r.status === "failed" && hasResults && (
                        <Checkbox
                          checked={selectedFailed.has(r.providerId)}
                          onCheckedChange={() => toggleSelectFailed(r.providerId)}
                        />
                      )}
                      <span className="font-medium">{r.providerName}</span>
                    </div>
                    <div className="flex items-center gap-2">
                      {r.status === "pending" && (
                        <Badge variant="outline">{t("pending")}</Badge>
                      )}
                      {r.status === "testing" && (
                        <Badge variant="secondary">
                          <Loader2 className="h-3 w-3 animate-spin mr-1" />
                          {t("testing")}
                        </Badge>
                      )}
                      {r.status === "success" && (
                        <Badge
                          variant="default"
                          className="bg-green-600 cursor-pointer hover:bg-green-700"
                          onClick={() => r.resultData && setViewingResult(r)}
                        >
                          {t("success")} {r.latencyMs && `(${r.latencyMs}ms)`}
                        </Badge>
                      )}
                      {r.status === "failed" && (
                        <Badge
                          variant="destructive"
                          className="cursor-pointer hover:bg-destructive/80"
                          onClick={() => r.resultData && setViewingResult(r)}
                          title={r.errorMessage}
                        >
                          {t("failed")}
                          <ExternalLink className="h-3 w-3 ml-1" />
                        </Badge>
                      )}
                    </div>
                  </div>
                ))}
              </div>
            </div>
          )}

          {/* 详情查看弹窗 */}
          <Dialog open={!!viewingResult} onOpenChange={(open) => !open && setViewingResult(null)}>
            <DialogContent className="max-w-2xl max-h-[85vh] overflow-y-auto">
              <DialogHeader>
                <DialogTitle>{viewingResult?.providerName}</DialogTitle>
                <DialogDescription>
                  {viewingResult?.status === "success" ? t("success") : t("failed")}
                  {viewingResult?.latencyMs && ` - ${viewingResult.latencyMs}ms`}
                </DialogDescription>
              </DialogHeader>
              {viewingResult?.resultData && (
                <TestResultCard result={viewingResult.resultData} />
              )}
            </DialogContent>
          </Dialog>

          {/* 结果摘要 */}
          {hasResults && (
            <div className="text-sm">
              {failedCount === 0 ? (
                <span className="text-green-600">{t("allSuccess")}</span>
              ) : (
                <span className="text-destructive">{t("hasFailed", { count: failedCount })}</span>
              )}
            </div>
          )}
        </div>

        <DialogFooter className="flex-col sm:flex-row gap-2">
          {/* 左侧操作按钮 */}
          {hasResults && failedCount > 0 && (
            <div className="flex gap-2 mr-auto">
              <Button variant="outline" size="sm" onClick={selectAllFailed}>
                {t("selectAll")}
              </Button>
              {selectedFailed.size > 0 && (
                <Button variant="destructive" size="sm" onClick={handleDisableSelected}>
                  {t("disableSelected", { count: selectedFailed.size })}
                </Button>
              )}
              <Button variant="destructive" size="sm" onClick={handleDisableAllFailed}>
                {t("disableAllFailed")}
              </Button>
            </div>
          )}

          {/* 右侧控制按钮 */}
          <div className="flex gap-2">
            {testing ? (
              <Button variant="outline" onClick={handleStop}>
                <X className="h-4 w-4 mr-1" />
                {t("stopTest")}
              </Button>
            ) : (
              <>
                <Button variant="outline" onClick={() => setOpen(false)}>
                  {t("close")}
                </Button>
                <Button
                  onClick={handleStartTest}
                  disabled={enabledProviders.length === 0 || !model.trim()}
                >
                  {hasResults ? t("retry") : t("startTest")}
                </Button>
              </>
            )}
          </div>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
