"use client";

import { DollarSign, Edit2, RefreshCw, Wallet } from "lucide-react";
import { useFormatter, useTranslations } from "next-intl";
import { useCallback, useEffect, useState, useTransition } from "react";
import { toast } from "sonner";
import {
  fetchProviderBalanceFromApi,
  getProvidersBalanceSummary,
  refreshAllProviderBalances,
  updateProviderBalance,
  type ProviderBalanceInfo,
} from "@/actions/providers";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

export function BalanceClient() {
  const t = useTranslations("quota.balance");
  const formatter = useFormatter();
  const [loading, setLoading] = useState(true);
  const [totalBalance, setTotalBalance] = useState(0);
  const [providers, setProviders] = useState<ProviderBalanceInfo[]>([]);
  const [refreshing, startRefreshTransition] = useTransition();
  const [refreshingAll, startRefreshAllTransition] = useTransition();
  const [editDialogOpen, setEditDialogOpen] = useState(false);
  const [editingProvider, setEditingProvider] = useState<ProviderBalanceInfo | null>(null);
  const [editBalance, setEditBalance] = useState("");
  const [saving, startSaveTransition] = useTransition();
  const [refreshingProviderId, setRefreshingProviderId] = useState<number | null>(null);

  const fetchData = useCallback(async () => {
    const result = await getProvidersBalanceSummary();
    if (result.ok && result.data) {
      setTotalBalance(result.data.totalBalance);
      setProviders(result.data.providers);
    }
    setLoading(false);
  }, []);

  useEffect(() => {
    fetchData();
  }, [fetchData]);

  const handleRefreshSingle = (providerId: number, providerName: string) => {
    startRefreshTransition(async () => {
      setRefreshingProviderId(providerId);
      try {
        const result = await fetchProviderBalanceFromApi(providerId);
        if (result.ok && result.data) {
          toast.success(t("refreshSuccess"), {
            description: t("refreshSuccessDesc", { name: providerName, balance: result.data.balance.toFixed(2) }),
          });
          fetchData();
        } else if (!result.ok) {
          toast.error(t("refreshFailed"), { description: result.error });
        }
      } finally {
        setRefreshingProviderId(null);
      }
    });
  };

  const handleRefreshAll = () => {
    startRefreshAllTransition(async () => {
      const result = await refreshAllProviderBalances();
      if (result.ok && result.data) {
        if (result.data.success > 0) {
          toast.success(t("refreshAllSuccess"), {
            description: t("refreshAllSuccessDesc", { success: result.data.success, failed: result.data.failed }),
          });
        }
        if (result.data.failed > 0) {
          toast.warning(t("refreshAllPartialFailed"), { description: result.data.errors.slice(0, 3).join("\n") });
        }
        fetchData();
      } else if (!result.ok) {
        toast.error(t("refreshAllFailed"), { description: result.error });
      }
    });
  };

  const handleOpenEdit = (provider: ProviderBalanceInfo) => {
    setEditingProvider(provider);
    setEditBalance(provider.balance?.toString() ?? "");
    setEditDialogOpen(true);
  };

  const handleSaveBalance = () => {
    if (!editingProvider) return;
    const balance = parseFloat(editBalance);
    if (isNaN(balance) || balance < 0) {
      toast.error(t("invalidBalance"));
      return;
    }
    startSaveTransition(async () => {
      const result = await updateProviderBalance(editingProvider.providerId, balance);
      if (result.ok) {
        toast.success(t("updateSuccess"), {
          description: t("updateSuccessDesc", { name: editingProvider.providerName, balance: balance.toFixed(2) }),
        });
        setEditDialogOpen(false);
        fetchData();
      } else {
        toast.error(t("updateFailed"), { description: result.error });
      }
    });
  };

  const formatTime = useCallback(
    (date: Date | string | null) => {
      if (!date) return t("lastUpdatedNever");
      const parsed = date instanceof Date ? date : new Date(date);
      if (Number.isNaN(parsed.getTime())) {
        return t("lastUpdatedNever");
      }
      return formatter.dateTime(parsed, { dateStyle: "medium", timeStyle: "short" });
    },
    [formatter, t]
  );

  if (loading) {
    return (
      <div className="space-y-4">
        <Skeleton className="h-32 w-full" />
        <Skeleton className="h-64 w-full" />
      </div>
    );
  }

  return (
    <div className="space-y-6">
      <Card>
        <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
          <CardTitle className="text-sm font-medium">{t("totalBalance")}</CardTitle>
          <Wallet className="h-4 w-4 text-muted-foreground" />
        </CardHeader>
        <CardContent>
          <div className="text-2xl font-bold">${totalBalance.toFixed(2)}</div>
          <p className="text-xs text-muted-foreground">
            {t("providerCount", { count: providers.filter((p) => p.balance !== null).length })}
          </p>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <div className="flex items-center justify-between">
            <div>
              <CardTitle>{t("providerBalances")}</CardTitle>
              <CardDescription>{t("providerBalancesDesc")}</CardDescription>
            </div>
            <Button variant="outline" size="sm" onClick={handleRefreshAll} disabled={refreshingAll}>
              <RefreshCw className={`mr-2 h-4 w-4 ${refreshingAll ? "animate-spin" : ""}`} />
              {t("refreshAll")}
            </Button>
          </div>
        </CardHeader>
        <CardContent>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>{t("columns.provider")}</TableHead>
                <TableHead className="text-right">{t("columns.balance")}</TableHead>
                <TableHead>{t("columns.lastUpdated")}</TableHead>
                <TableHead className="text-right">{t("columns.actions")}</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {providers.map((provider) => (
                <TableRow key={provider.providerId}>
                  <TableCell className="font-medium">
                    <div className="flex flex-col gap-1">
                      <span>{provider.providerName}</span>
                      <Badge
                        variant={provider.balanceFetchEnabled ? "default" : "outline"}
                        className="w-fit text-xs font-normal"
                      >
                        {provider.balanceFetchEnabled
                          ? t("autoFetch.enabled")
                          : t("autoFetch.disabled")}
                      </Badge>
                    </div>
                  </TableCell>
                  <TableCell className="text-right">
                    {provider.balance !== null ? (
                      <span className="flex items-center justify-end gap-1">
                        <DollarSign className="h-4 w-4 text-green-600" />
                        {provider.balance.toFixed(2)}
                      </span>
                    ) : (
                      <span className="text-muted-foreground">{t("notSet")}</span>
                    )}
                  </TableCell>
                  <TableCell className="text-muted-foreground text-sm">
                    {formatTime(provider.lastUpdated)}
                  </TableCell>
                  <TableCell className="text-right">
                    <div className="flex items-center justify-end gap-2">
                      <Button
                        variant="ghost"
                        size="icon"
                        onClick={() => handleRefreshSingle(provider.providerId, provider.providerName)}
                        disabled={refreshing}
                        title={t("refreshFromApi")}
                      >
                        <RefreshCw
                          className={`h-4 w-4 ${
                            refreshing && refreshingProviderId === provider.providerId ? "animate-spin" : ""
                          }`}
                        />
                      </Button>
                      <Button variant="ghost" size="icon" onClick={() => handleOpenEdit(provider)} title={t("editBalance")}>
                        <Edit2 className="h-4 w-4" />
                      </Button>
                    </div>
                  </TableCell>
                </TableRow>
              ))}
              {providers.length === 0 && (
                <TableRow>
                  <TableCell colSpan={4} className="text-center text-muted-foreground">{t("noProviders")}</TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      <Dialog open={editDialogOpen} onOpenChange={setEditDialogOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{t("editBalanceTitle")}</DialogTitle>
            <DialogDescription>{t("editBalanceDesc", { name: editingProvider?.providerName ?? "" })}</DialogDescription>
          </DialogHeader>
          <div className="grid gap-4 py-4">
            <div className="grid grid-cols-4 items-center gap-4">
              <Label htmlFor="balance" className="text-right">{t("balanceLabel")}</Label>
              <Input id="balance" type="number" step="0.01" min="0" value={editBalance} onChange={(e) => setEditBalance(e.target.value)} className="col-span-3" placeholder="0.00" />
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setEditDialogOpen(false)}>{t("cancel")}</Button>
            <Button onClick={handleSaveBalance} disabled={saving}>{saving ? t("saving") : t("save")}</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
