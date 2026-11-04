import { useId } from "react";
import Svg, { Defs, LinearGradient, Stop, Path, ClipPath, G } from "react-native-svg";

type BrandSymbolProps = {
  size?: number;
  monochrome?: boolean;
};

export function BrandSymbol({ size = 56, monochrome = false }: BrandSymbolProps) {
  const uniqueId = useId().replace(/:/g, "");
  const gradientId = `brandWaterGradient-${uniqueId}`;
  const clipId = `brandDropClip-${uniqueId}`;
  const fill = monochrome ? "#145B7A" : `url(#${gradientId})`;
  const dropPath = "M160 18C140 55 75 126 75 188c0 52 38 94 85 94s85-42 85-94C245 126 180 55 160 18Z";

  return (
    <Svg
      width={size}
      height={size}
      viewBox="0 0 320 320"
      accessible
      accessibilityLabel="شعار إدارة المياه"
    >
      <Defs>
        {!monochrome && (
          <LinearGradient id={gradientId} x1="0" y1="0" x2="1" y2="1">
            <Stop offset="0" stopColor="#1B9AAA" />
            <Stop offset="0.52" stopColor="#087FA8" />
            <Stop offset="1" stopColor="#145B7A" />
          </LinearGradient>
        )}
        <ClipPath id={clipId}>
          <Path d={dropPath} />
        </ClipPath>
      </Defs>
      <Path fill={fill} d={dropPath} />
      <G clipPath={`url(#${clipId})`}>
        <Path
          d="M67 165c27-25 53-28 79-13 24 14 48 16 77-7 12-10 25-14 39-12"
          fill="none"
          stroke="#FFFFFF"
          strokeWidth={18}
          strokeLinecap="round"
          strokeLinejoin="round"
        />
        <Path
          d="M58 199c31-27 58-29 87-13 28 16 54 14 83-10 12-10 24-13 37-11"
          fill="none"
          stroke="#FFFFFF"
          strokeWidth={18}
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      </G>
    </Svg>
  );
}
