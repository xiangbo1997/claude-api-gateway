import { getTranslations } from "next-intl/server";
import { TabsContent } from "@/components/ui/tabs";
import { BalanceClient } from "./_components/balance-client";

export default async function BalancePage() {
  const t = await getTranslations("quota.balance");

  return (
    <TabsContent value="balance" className="space-y-4">
      <div className="flex items-center justify-between">
        <div>
          <h3 className="text-lg font-medium">{t("title")}</h3>
          <p className="text-sm text-muted-foreground">{t("description")}</p>
        </div>
      </div>
      <BalanceClient />
    </TabsContent>
  );
}
