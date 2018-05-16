
#include <stdint.h>
#include <avisynth.h>

#include <algorithm>
#include <memory>

#include "CommonFunctions.h"
#include "KFM.h"
#include "TextOut.h"
#include "AMTGenTime.hpp"

#include "VectorFunctions.cuh"
#include "ReduceKernel.cuh"
#include "KFMFilterBase.cuh"

class KPatchCombe : public KFMFilterBase
{
  PClip clip60;
  PClip combemaskclip;
  PClip containscombeclip;
  PClip fmclip;

  PulldownPatterns patterns;

  template <typename pixel_t>
  PVideoFrame GetFrameT(int n, PNeoEnv env)
  {
    PDevice cpuDevice = env->GetDevice(DEV_TYPE_CPU, 0);

    {
      Frame containsframe = env->GetFrame(containscombeclip, n, cpuDevice);
      if (*containsframe.GetReadPtr<int>() == 0) {
        // ダメなブロックはないのでそのまま返す
        return child->GetFrame(n, env);
      }
    }

    int cycleIndex = n / 4;
    Frame fmframe = env->GetFrame(fmclip, cycleIndex, cpuDevice);
    int kfmPattern = fmframe.GetProperty("KFM_Pattern", -1);
    if (kfmPattern == -1) {
      env->ThrowError("[KPatchCombe] Failed to get frame info. Check fmclip");
    }
    Frame24Info frameInfo = patterns.GetFrame24(kfmPattern, n);

    int fieldIndex[] = { 1, 3, 6, 8 };
    // 標準位置
    int n60 = fieldIndex[n % 4];
    // フィールド対象範囲に補正
    n60 = clamp(n60, frameInfo.fieldStartIndex, frameInfo.fieldStartIndex + frameInfo.numFields - 1);
    n60 += cycleIndex * 10;

    Frame baseFrame = child->GetFrame(n, env);
    Frame frame60 = clip60->GetFrame(n60, env);
    Frame mflag = combemaskclip->GetFrame(n, env);

    // ダメなブロックはbobフレームからコピー
    Frame dst = env->NewVideoFrame(vi);
    MergeBlock<pixel_t>(baseFrame, frame60, mflag, dst, env);

    return dst.frame;
  }

public:
  KPatchCombe(PClip clip24, PClip clip60, PClip fmclip, PClip combemaskclip, PClip containscombeclip, IScriptEnvironment* env)
    : KFMFilterBase(clip24)
    , clip60(clip60)
    , combemaskclip(combemaskclip)
    , containscombeclip(containscombeclip)
    , fmclip(fmclip)
  {
    //
  }

  PVideoFrame __stdcall GetFrame(int n, IScriptEnvironment* env_)
  {
    PNeoEnv env = env_;

    int pixelSize = vi.ComponentSize();
    switch (pixelSize) {
    case 1:
      return GetFrameT<uint8_t>(n, env);
    case 2:
      return GetFrameT<uint16_t>(n, env);
    default:
      env->ThrowError("[KPatchCombe] Unsupported pixel format");
    }

    return PVideoFrame();
  }

  static AVSValue __cdecl Create(AVSValue args, void* user_data, IScriptEnvironment* env)
  {
    return new KPatchCombe(
      args[0].AsClip(),       // clip24
      args[1].AsClip(),       // clip60
      args[2].AsClip(),       // fmclip
      args[3].AsClip(),       // combemaskclip
      args[4].AsClip(),       // containscombeclip
      env
    );
  }
};

enum KFMSWTICH_FLAG {
  FRAME_60 = 1,
  FRAME_30,
	FRAME_24,
  FRAME_UCF,
};

class KFMSwitch : public KFMFilterBase
{
	typedef uint8_t pixel_t;

  VideoInfo srcvi;

  PClip clip24;
  PClip mask24;
  PClip cc24;
  
  PClip clip30;
  PClip mask30;
  PClip cc30;

	PClip fmclip;
  PClip combemaskclip;
  PClip containscombeclip;
  PClip ucfclip;
	float thswitch;
  bool gentime;
	bool show;
	bool showflag;

	int logUVx;
	int logUVy;
	int nBlkX, nBlkY;

  AMTGenTime amtgentime;
	PulldownPatterns patterns;

	template <typename pixel_t>
	void VisualizeFlag(Frame& dst, Frame& flag, PNeoEnv env)
	{
		// 判定結果を表示
		int blue[] = { 73, 230, 111 };

		pixel_t* dstY = dst.GetWritePtr<pixel_t>(PLANAR_Y);
		pixel_t* dstU = dst.GetWritePtr<pixel_t>(PLANAR_U);
		pixel_t* dstV = dst.GetWritePtr<pixel_t>(PLANAR_V);
    const uint8_t* flagY = flag.GetReadPtr<uint8_t>(PLANAR_Y);
    const uint8_t* flagC = flag.GetReadPtr<uint8_t>(PLANAR_U);

		int dstPitchY = dst.GetPitch<pixel_t>(PLANAR_Y);
		int dstPitchUV = dst.GetPitch<pixel_t>(PLANAR_U);
    int fpitchY = flag.GetPitch<uint8_t>(PLANAR_Y);
    int fpitchUV = flag.GetPitch<uint8_t>(PLANAR_U);

		// 色を付ける
		for (int y = 0; y < srcvi.height; ++y) {
			for (int x = 0; x < srcvi.width; ++x) {
        int coefY = flagY[x + y * fpitchY];
				int offY = x + y * dstPitchY;
        dstY[offY] = (blue[0] * coefY + dstY[offY] * (128 - coefY)) >> 7;
        
        int coefC = flagC[(x >> logUVx) + (y >> logUVy) * fpitchUV];
				int offUV = (x >> logUVx) + (y >> logUVy) * dstPitchUV;
				dstU[offUV] = (blue[1] * coefC + dstU[offUV] * (128 - coefC)) >> 7;
				dstV[offUV] = (blue[2] * coefC + dstV[offUV] * (128 - coefC)) >> 7;
			}
		}
	}

  Frame MakeFrameFps(int fps, int source, PNeoEnv env) {
    Frame frame = env->NewVideoFrame(vi);
    auto ptr = frame.GetWritePtr<AMTFrameFps>();
    ptr->fps = fps;
    ptr->source = source;
    return frame;
  }

	template <typename pixel_t>
	Frame InternalGetFrame(int n60, Frame& fmframe, int& type, PNeoEnv env)
	{
		int cycleIndex = n60 / 10;
		int kfmPattern = fmframe.GetProperty("KFM_Pattern", -1);
    if (kfmPattern == -1) {
      env->ThrowError("[KFMSwitch] Failed to get frame info. Check fmclip");
    }
		float kfmCost = (float)fmframe.GetProperty("KFM_Cost", 1.0);
    Frame baseFrame;

		if (kfmCost > thswitch) {
			// コストが高いので60pと判断
      type = FRAME_60;

      if (gentime) {
        return MakeFrameFps(AMT_FPS_60, n60, env);
      }

      if (ucfclip) {
        baseFrame = ucfclip->GetFrame(n60, env);
        auto prop = baseFrame.GetProperty(DECOMB_UCF_FLAG_STR);
        if (prop == nullptr) {
          env->ThrowError("Invalid UCF clip");
        }
        auto flag = (DECOMB_UCF_FLAG)prop->GetInt();
        if (flag == DECOMB_UCF_NEXT || flag == DECOMB_UCF_PREV) {
          // フレーム置換がされた場合は、60p部分マージ処理を実行する
          type = FRAME_UCF;
        }
        else {
          return baseFrame;
        }
      }
      else {
        return child->GetFrame(n60, env);
      }
		}

    // ここでのtypeは 24 or 30 or UCF
    Frame mflag;

    if (PulldownPatterns::Is30p(kfmPattern)) {
      // 30p
      int n30 = n60 >> 1;

      if (!baseFrame) {
        if (!gentime) {
          baseFrame = clip30->GetFrame(n30, env);
        }
        type = FRAME_30;
      }

      Frame containsframe = env->GetFrame(cc30, n30, env->GetDevice(DEV_TYPE_CPU, 0));
      if (*containsframe.GetReadPtr<int>() == 0) {
        // ダメなブロックはないのでそのまま返す
        if (gentime) {
          return MakeFrameFps(AMT_FPS_30, n30, env);
        }
        return baseFrame;
      }
      else if (gentime) {
        // ダメなブロックがあるときは60fps
        return MakeFrameFps(AMT_FPS_60, n60, env);
      }

      mflag = mask30->GetFrame(n30, env);
    }
    else {
      // 24pフレーム番号を取得
      Frame24Info frameInfo = patterns.GetFrame60(kfmPattern, n60);
      int n24 = frameInfo.cycleIndex * 4 + frameInfo.frameIndex + frameInfo.fieldShift;

      if (frameInfo.frameIndex < 0) {
        // 前に空きがあるので前のサイクル
        n24 = frameInfo.cycleIndex * 4 - 1;
      }
      else if (frameInfo.frameIndex >= 4) {
        // 後ろのサイクルのパターンを取得
        Frame nextfmframe = fmclip->GetFrame(cycleIndex + 1, env);
        int nextPattern = nextfmframe.GetProperty("KFM_Pattern", -1);
        int fstart = patterns.GetFrame24(nextPattern, 0).fieldStartIndex;
        if (fstart > 0) {
          // 前に空きがあるので前のサイクル
          n24 = frameInfo.cycleIndex * 4 + 3;
        }
        else {
          // 前に空きがないので後ろのサイクル
          n24 = frameInfo.cycleIndex * 4 + 4;
        }
      }

      if (!baseFrame) {
        if (!gentime) {
          baseFrame = clip24->GetFrame(n24, env);
        }
        type = FRAME_24;
      }

      Frame containsframe = env->GetFrame(cc24, n24, env->GetDevice(DEV_TYPE_CPU, 0));
      if (*containsframe.GetReadPtr<int>() == 0) {
        // ダメなブロックはないのでそのまま返す
        if (gentime) {
          return MakeFrameFps(AMT_FPS_24, n24, env);
        }
        return baseFrame;
      }
      else if (gentime) {
        // ダメなブロックがあるときは60fps
        return MakeFrameFps(AMT_FPS_60, n60, env);
      }

      mflag = mask24->GetFrame(n24, env);
    }

    Frame frame60 = child->GetFrame(n60, env);

		if (!IS_CUDA && srcvi.ComponentSize() == 1 && showflag) {
			env->MakeWritable(&baseFrame.frame);
			VisualizeFlag<pixel_t>(baseFrame, mflag, env);
			return baseFrame;
		}

		// ダメなブロックはbobフレームからコピー
		Frame dst = env->NewVideoFrame(srcvi);
		MergeBlock<pixel_t>(baseFrame, frame60, mflag, dst, env);

		return dst;
	}

  static const char* FrameTypeStr(int frameType)
  {
    switch (frameType) {
    case FRAME_60: return "60p";
    case FRAME_30: return "30p";
    case FRAME_24: return "24p";
    case FRAME_UCF: return "UCF";
    }
    return "???";
  }

  template <typename pixel_t>
  PVideoFrame GetFrameTop(int n60, PNeoEnv env)
  {
    int cycleIndex = n60 / 10;
    Frame fmframe = env->GetFrame(fmclip, cycleIndex, env->GetDevice(DEV_TYPE_CPU, 0));
    int frameType;

    Frame dst = InternalGetFrame<pixel_t>(n60, fmframe, frameType, env);

    if (!gentime && show) {
      const std::pair<int, float>* pfm = fmframe.GetReadPtr<std::pair<int, float>>();
      const char* fps = FrameTypeStr(frameType);
      char buf[100]; sprintf(buf, "KFMSwitch: %s pattern:%2d cost:%.1f", fps, pfm->first, pfm->second);
      DrawText<pixel_t>(dst.frame, srcvi.BitsPerComponent(), 0, 0, buf, env);
      return dst.frame;
    }

    return dst.frame;
  }

public:
	KFMSwitch(PClip clip60, PClip fmclip,
    PClip clip24, PClip mask24, PClip cc24,
    PClip clip30, PClip mask30, PClip cc30,
    PClip ucfclip,
		float thswitch, bool gentime, bool show, bool showflag, IScriptEnvironment* env)
		: KFMFilterBase(clip60)
    , srcvi(vi)
    , fmclip(fmclip)
    , clip24(clip24)
    , mask24(mask24)
    , cc24(cc24)
    , clip30(clip30)
    , mask30(mask30)
    , cc30(cc30)
    , ucfclip(ucfclip)
		, thswitch(thswitch)
    , gentime(gentime)
		, show(show)
		, showflag(showflag)
		, logUVx(vi.GetPlaneWidthSubsampling(PLANAR_U))
		, logUVy(vi.GetPlaneHeightSubsampling(PLANAR_U))
	{
		if (vi.width & 7) env->ThrowError("[KFMSwitch]: width must be multiple of 8");
		if (vi.height & 7) env->ThrowError("[KFMSwitch]: height must be multiple of 8");

		nBlkX = nblocks(vi.width, OVERLAP);
		nBlkY = nblocks(vi.height, OVERLAP);

    // check clip device
    if (!(GetDeviceTypes(fmclip) & DEV_TYPE_CPU)) {
      env->ThrowError("[KFMSwitch]: fmclip must be CPU device");
    }
    if (!(GetDeviceTypes(cc24) & DEV_TYPE_CPU)) {
      env->ThrowError("[KFMSwitch]: cc24 must be CPU device");
    }
    if (!(GetDeviceTypes(cc30) & DEV_TYPE_CPU)) {
      env->ThrowError("[KFMSwitch]: cc30 must be CPU device");
    }

    auto devs = GetDeviceTypes(clip60);
    if (!(GetDeviceTypes(clip24) & devs)) {
      env->ThrowError("[KFMSwitch]: clip24 device unmatch");
    }
    if (!(GetDeviceTypes(clip30) & devs)) {
      env->ThrowError("[KFMSwitch]: clip30 device unmatch");
    }
    if (!(GetDeviceTypes(mask24) & devs)) {
      env->ThrowError("[KFMSwitch]: mask24 device unmatch");
    }
    if (!(GetDeviceTypes(mask30) & devs)) {
      env->ThrowError("[KFMSwitch]: mask30 device unmatch");
    }
    if (ucfclip && !(GetDeviceTypes(ucfclip) & devs)) {
      env->ThrowError("[KFMSwitch]: ucfclip device unmatch");
    }
    
    if (gentime) {
      vi.pixel_type = VideoInfo::CS_BGR32;
      vi.width = 2;
      vi.height = nblocks(sizeof(AMTFrameFps), vi.width * 4);
      AMTGenTime::SetParam(vi, &amtgentime);
    }
	}

	PVideoFrame __stdcall GetFrame(int n60, IScriptEnvironment* env_)
	{
		PNeoEnv env = env_;

		int pixelSize = srcvi.ComponentSize();
		switch (pixelSize) {
		case 1:
			return GetFrameTop<uint8_t>(n60, env);
		case 2:
      return GetFrameTop<uint16_t>(n60, env);
		default:
			env->ThrowError("[KFMSwitch] Unsupported pixel format");
			break;
		}

		return PVideoFrame();
	}

  int __stdcall SetCacheHints(int cachehints, int frame_range) {
    if (cachehints == CACHE_GET_DEV_TYPE) {
      if (gentime) {
        // フレーム時間生成はCPUフレームを返す
        return DEV_TYPE_CPU;
      }
      else {
        return GetDeviceTypes(child) &
          (DEV_TYPE_CPU | DEV_TYPE_CUDA);
      }
    }
    else if (cachehints == CACHE_GET_CHILD_DEV_TYPE) {
      // フレーム時間生成時でも子はGPUでOKなので
      return GetDeviceTypes(child) &
        (DEV_TYPE_CPU | DEV_TYPE_CUDA);
    }
    return 0;
  }

	static AVSValue __cdecl Create(AVSValue args, void* user_data, IScriptEnvironment* env)
	{
		return new KFMSwitch(
			args[0].AsClip(),           // clip60
      args[1].AsClip(),           // fmclip
      args[2].AsClip(),           // clip24
      args[3].AsClip(),           // mask24
      args[4].AsClip(),           // cc24
      args[5].AsClip(),           // clip30
			args[6].AsClip(),           // mask30
      args[7].AsClip(),           // cc30
      args[8].Defined() ? args[5].AsClip() : nullptr,           // ucfclip
      (float)args[9].AsFloat(3.0f),// thswitch
      args[10].AsBool(false),      // gentime
      args[11].AsBool(false),      // show
			args[12].AsBool(false),      // showflag
			env
			);
	}
};

class AMTVFRShow : public GenericVideoFilter
{
  PClip vfrclip;

  const AMTGenTime* gentime_;

  const char* FrameTypeStr(int fps) {
    switch (fps) {
    case AMT_FPS_24: return "24p";
    case AMT_FPS_30: return "30p";
    case AMT_FPS_60: return "60p";
    }
    return "Unknown";
  }

  template <typename pixel_t>
  PVideoFrame GetFrameT(int n60, PNeoEnv env)
  {
    Frame timeframe = env->GetFrame(vfrclip, n60, env->GetDevice(DEV_TYPE_CPU, 0));
    const AMTFrameFps* frameFps = timeframe.GetReadPtr<AMTFrameFps>();
    char buf[100]; sprintf(buf, "KFM VFR: %s %d", 
      FrameTypeStr(frameFps->fps), frameFps->source);
    Frame dst = child->GetFrame(n60, env);
    env->MakeWritable(&dst.frame);
    DrawText<pixel_t>(dst.frame, vi.BitsPerComponent(), 0, 0, buf, env);
    return dst.frame;
  }

public:
  AMTVFRShow(PClip bob, PClip vfrclip, PNeoEnv env)
    : GenericVideoFilter(bob)
    , vfrclip(vfrclip)
    , gentime_(AMTGenTime::GetParam(vfrclip->GetVideoInfo()))
  {
    if (gentime_ == nullptr) {
      env->ThrowError("vfrクリップが不正");
    }
  }

  PVideoFrame __stdcall GetFrame(int n, IScriptEnvironment* env_)
  {
    PNeoEnv env = env_;

    int pixelSize = vi.ComponentSize();
    switch (pixelSize) {
    case 1:
      return GetFrameT<uint8_t>(n, env);
    case 2:
      return GetFrameT<uint16_t>(n, env);
    default:
      env->ThrowError("[AMTVFRShow] Unsupported pixel format");
      break;
    }

    return PVideoFrame();
  }

  static AVSValue __cdecl Create(AVSValue args, void* user_data, IScriptEnvironment* env)
  {
    return new AMTVFRShow(
      args[0].AsClip(),           // clip60
      args[1].AsClip(),           // vfrclip
      env
    );
  }
};

class KFMPad : public KFMFilterBase
{
  VideoInfo srcvi;

  template <typename pixel_t>
  PVideoFrame GetFrameT(int n, PNeoEnv env)
  {
    Frame src = child->GetFrame(n, env);
    Frame dst = Frame(env->NewVideoFrame(vi), VPAD);

    CopyFrame<pixel_t>(src, dst, env);
    PadFrame<pixel_t>(dst, env);

    return dst.frame;
  }
public:
  KFMPad(PClip src, IScriptEnvironment* env)
    : KFMFilterBase(src)
    , srcvi(vi)
  {
    if (srcvi.width & 3) env->ThrowError("[KFMPad]: width must be multiple of 4");
    if (srcvi.height & 3) env->ThrowError("[KFMPad]: height must be multiple of 4");

    vi.height += VPAD * 2;
  }

  PVideoFrame __stdcall GetFrame(int n, IScriptEnvironment* env_)
  {
    PNeoEnv env = env_;

    int pixelSize = vi.ComponentSize();
    switch (pixelSize) {
    case 1:
      return GetFrameT<uint8_t>(n, env);
    case 2:
      return GetFrameT<uint16_t>(n, env);
    default:
      env->ThrowError("[KFMPad] Unsupported pixel format");
      break;
    }

    return PVideoFrame();
  }

  static AVSValue __cdecl Create(AVSValue args, void* user_data, IScriptEnvironment* env)
  {
    return new KFMPad(
      args[0].AsClip(),       // src
      env
    );
  }
};


class AssumeDevice : public GenericVideoFilter
{
  int devices;
public:
  AssumeDevice(PClip clip, int devices)
    : GenericVideoFilter(clip)
    , devices(devices)
  { }

	int __stdcall SetCacheHints(int cachehints, int frame_range) {
		if (cachehints == CACHE_GET_DEV_TYPE) {
			return devices;
		}
		return 0;
	}

	static AVSValue __cdecl Create(AVSValue args, void* user_data, IScriptEnvironment* env)
	{
		return new AssumeDevice(args[0].AsClip(), args[1].AsInt());
	}
};

void AddFuncFMKernel(IScriptEnvironment* env)
{
  env->AddFunction("KPatchCombe", "ccccc", KPatchCombe::Create, 0);
  env->AddFunction("KFMSwitch", "cccccccc[ucfclip]c[thswitch]f[gentime]b[show]b[showflag]b", KFMSwitch::Create, 0);
  env->AddFunction("AMTVFRShow", "cc", AMTVFRShow::Create, 0);
  env->AddFunction("KFMPad", "c", KFMPad::Create, 0);
	env->AddFunction("AssumeDevice", "ci", AssumeDevice::Create, 0);
}
